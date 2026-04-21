#!/bin/bash
# scripts/lib/ocr.sh
#
# OCR wrapper. Two backends, tried in this order:
#
#   1. OpenAI vision (preferred). Sends the image to gpt-4o-mini with a
#      "extract all text verbatim" prompt. Handles hand-drawn diagrams,
#      screenshots with UI chrome, etc.
#      - Config: OPENAI_API_KEY in secrets.env.
#   2. macOS Vision framework via osascript.
#      - Config: none (works on macOS 13+).
#      - Calls `ocrmypdf` if installed, otherwise uses a tiny Swift snippet
#        via `swift` if available, otherwise `osascript` + AppleScript.
#
# The macOS backend is offered as the zero-cost fallback for privacy-conscious
# users. Accuracy is usually fine for screenshots of text.
#
# Callers:
#   ocr_image <path-to-jpg-png> → echoes extracted text (may be multi-line)

[[ -n "${_DEV_AGENT_OCR_LOADED:-}" ]] && return 0
_DEV_AGENT_OCR_LOADED=1

_ocr_openai() {
  local img="$1"
  local key="${OPENAI_API_KEY:-}"
  [[ -z "$key" ]] && return 10

  command -v base64 >/dev/null 2>&1 || { echo "ocr: base64 missing" >&2; return 2; }

  local mime ext
  case "${img##*.}" in
    jpg|jpeg|JPG|JPEG) mime="image/jpeg" ;;
    png|PNG)           mime="image/png"  ;;
    webp|WEBP)         mime="image/webp" ;;
    gif|GIF)           mime="image/gif"  ;;
    *)                 mime="image/png"  ;;
  esac
  ext="$mime"

  # macOS base64 emits one line; Linux may wrap. Use -i on macOS, fall back
  # to tr on Linux.
  local b64
  b64=$(base64 -i "$img" 2>/dev/null || base64 -w0 "$img" 2>/dev/null)
  [[ -z "$b64" ]] && { echo "ocr: base64 encoding failed" >&2; return 1; }

  local body
  body=$(MIME="$ext" B64="$b64" python3 -c '
import json, os
body = {
    "model": "gpt-4o-mini",
    "messages": [{
        "role": "user",
        "content": [
            {"type": "text", "text": "Extract ALL text visible in this image, verbatim. Preserve line breaks and rough layout. Return only the text, no commentary."},
            {"type": "image_url", "image_url": {"url": f"data:{os.environ[\"MIME\"]};base64,{os.environ[\"B64\"]}"}}
        ]
    }],
    "max_tokens": 1200
}
print(json.dumps(body))
')

  local out
  out=$(curl -s --max-time 60 \
    -H "Authorization: Bearer $key" \
    -H "Content-Type: application/json" \
    --data "$body" \
    https://api.openai.com/v1/chat/completions 2>&1) || {
      echo "ocr: openai request failed: $out" >&2
      return 1
    }

  local parsed
  parsed=$(printf '%s' "$out" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception as e:
    print(f"__ERR__:invalid JSON: {e}"); sys.exit(0)
if "error" in d:
    print(f"__ERR__:{(d[\"error\"] or {}).get(\"message\",\"unknown\")}"); sys.exit(0)
ch = (d.get("choices") or [{}])[0]
msg = (ch.get("message") or {}).get("content") or ""
print(msg.strip())
')
  if [[ "$parsed" == __ERR__:* ]]; then
    echo "ocr: ${parsed#__ERR__:}" >&2
    return 1
  fi
  printf '%s' "$parsed"
}

_ocr_macos_vision() {
  local img="$1"
  [[ "$(uname)" == "Darwin" ]] || return 10
  command -v swift >/dev/null 2>&1 || return 10

  # Inline Swift script using the Vision framework. Compiled on the fly via
  # `swift`. Output goes to stdout; errors to stderr. Works on macOS 13+ where
  # VNRecognizeTextRequest is available.
  swift - "$img" 2>/dev/null <<'EOF'
import Foundation
#if canImport(Vision)
import Vision
import AppKit

let args = CommandLine.arguments
guard args.count >= 2 else { exit(2) }
let path = args[1]
let url = URL(fileURLWithPath: path)
guard let img = NSImage(contentsOf: url),
      let tiff = img.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let cg = bitmap.cgImage else {
    FileHandle.standardError.write(Data("ocr: failed to read image\n".utf8))
    exit(1)
}

let req = VNRecognizeTextRequest { (request, err) in
    if let err = err {
        FileHandle.standardError.write(Data("ocr: \(err.localizedDescription)\n".utf8))
        exit(1)
    }
    guard let obs = request.results as? [VNRecognizedTextObservation] else { exit(0) }
    let lines = obs.compactMap { $0.topCandidates(1).first?.string }
    print(lines.joined(separator: "\n"))
}
req.recognitionLevel = .accurate
req.usesLanguageCorrection = true

let handler = VNImageRequestHandler(cgImage: cg, options: [:])
do { try handler.perform([req]) } catch {
    FileHandle.standardError.write(Data("ocr: perform failed: \(error)\n".utf8))
    exit(1)
}
#else
FileHandle.standardError.write(Data("ocr: Vision framework unavailable\n".utf8))
exit(10)
#endif
EOF
}

ocr_image() {
  local img="$1"
  [[ -f "$img" ]] || { echo "ocr: file not found: $img" >&2; return 2; }

  local text rc
  text=$(_ocr_openai "$img")
  rc=$?
  if [[ $rc -eq 0 && -n "$text" ]]; then
    printf '%s' "$text"
    return 0
  fi
  if [[ $rc -eq 10 ]]; then
    # Try macOS Vision.
    text=$(_ocr_macos_vision "$img")
    rc=$?
    if [[ $rc -eq 0 && -n "$text" ]]; then
      printf '%s' "$text"
      return 0
    fi
    if [[ $rc -eq 10 ]]; then
      echo "ocr: no backend configured (set OPENAI_API_KEY or run on macOS 13+ with swift)" >&2
      return 11
    fi
  fi
  return 1
}
