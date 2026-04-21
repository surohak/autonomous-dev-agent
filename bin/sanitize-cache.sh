#!/bin/bash
# bin/sanitize-cache.sh — pre-publication audit for leaked PII.
#
# Scans one or more paths for patterns that shouldn't end up in a public
# commit: teammate emails, Slack IDs, Jira accountIds, API tokens,
# absolute paths on your Mac, common corporate domain names.
#
# Defaults to scanning everything except directories that are gitignored by
# design (cache/, logs/, node_modules/, .git/). If run with --all you can
# override that to include cache/logs for a sanity check.
#
# Usage:
#   bin/sanitize-cache.sh                # scan tracked content, report only
#   bin/sanitize-cache.sh --all          # also scan cache/ and logs/
#   bin/sanitize-cache.sh --redact FILE  # in-place redact PII in FILE
#   bin/sanitize-cache.sh path1 path2    # scan specific paths
#
# Exit code: 0 if nothing suspicious, 1 if matches found (use in CI).

set -euo pipefail

SCAN_ALL=0
REDACT_TARGET=""
declare -a TARGETS=()

while (( $# )); do
  case "$1" in
    --all)    SCAN_ALL=1; shift ;;
    --redact) REDACT_TARGET="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) TARGETS+=("$1"); shift ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if (( ${#TARGETS[@]} == 0 )); then
  # Default target: files that would actually be published.
  # If this is a git repo, use `git ls-files` — exactly the set of tracked
  # files. Untracked/gitignored files are skipped by design.
  if (( SCAN_ALL == 0 )) && git rev-parse --git-dir >/dev/null 2>&1; then
    mapfile -t TRACKED < <(git ls-files)
    if (( ${#TRACKED[@]} > 0 )); then
      TARGETS=("${TRACKED[@]}")
    else
      TARGETS=(".")
    fi
  else
    TARGETS=(".")
  fi
fi

# Patterns — keep regexes PCRE-safe for rg (fallback to grep -E).
# Each entry: "label|regex"
PATTERNS=(
  "jira_account_id|[0-9]{6}:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
  # slack IDs — require at least one digit in the trailing 8-10 chars so
  # we don't falsely match English words after a capital U (e.g. TROUBLESHOOTING).
  "slack_user_id|\\bU(?=[A-Z0-9]{8,10}\\b)[A-Z0-9]*[0-9][A-Z0-9]*\\b"
  # emails — skip obvious placeholder domains (example.com, your-company.*).
  "email|[A-Za-z0-9._%+-]+@(?!example\\.com|your-company)[A-Za-z0-9.-]+\\.(com|io|net|org|dev|co)"
  "abs_macos_path|/Users/[a-zA-Z0-9_.-]+/"
  "atlassian_token|ATATT[A-Za-z0-9_-]{10,}"
  "gitlab_token|glpat-[A-Za-z0-9_-]{20,}"
  "telegram_token|[0-9]{8,12}:AA[A-Za-z0-9_-]{30,}"
  "tempo_token|(?i)tempo[_-]?(?:api[_-]?)?token[\"'\\s:=]+[A-Za-z0-9_-]{20,}"
  "hardcoded_jira_site|(?i)mycompany\\.atlassian\\.net|acme\\.atlassian\\.net"
  "hardcoded_user_slug|(?<![A-Za-z])(john\\.doe|jane\\.doe)(?![A-Za-z])"
)

# Exclusions — don't report matches in these files (they're allowed to carry
# example tokens, or they're rendered artifacts users generate locally).
EXCLUDES=(
  "*.example.json"
  "secrets.env.example"
  "docs/AUDIT-identity-strings.md"
  "CHANGELOG.md"
  "SKILL.md"                 # rendered locally; gitignored; never committed
  "config.json"              # personal; gitignored
  "secrets.env"              # personal; gitignored
  "bin/sanitize-cache.sh"    # the patterns themselves are matches
  "bin/doctor.sh"            # example error messages contain tokens
  "/SETUP.md"                # legacy pre-public setup notes; gitignored
)

excl_args=()
for e in "${EXCLUDES[@]}"; do excl_args+=("--glob=!$e"); done
if (( SCAN_ALL == 0 )); then
  excl_args+=("--glob=!cache/**" "--glob=!logs/**" "--glob=!.git/**" "--glob=!node_modules/**")
fi

redact_file() {
  local f="$1"
  [[ -f "$f" ]] || { echo "redact: no such file $f"; exit 1; }
  python3 - "$f" <<'PY'
import re, sys, pathlib
f = pathlib.Path(sys.argv[1])
text = f.read_text()
subs = [
    # jira accountIds
    (r"[0-9]{6}:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
     "<redacted:jira-account-id>"),
    # slack IDs
    (r"\bU[A-Z0-9]{8,10}\b", "<redacted:slack-id>"),
    # emails (don't touch example.com / your-company)
    (r"[A-Za-z0-9._%+-]+@(?!example\.com|your-company)[A-Za-z0-9.-]+\.(?:com|io|net|org|dev|co)",
     "<redacted:email>"),
    # absolute macOS paths — keep only the /Users/ prefix
    (r"/Users/[a-zA-Z0-9_.-]+/", "/Users/<redacted>/"),
    # obvious tokens
    (r"ATATT[A-Za-z0-9_-]{10,}",   "<redacted:atlassian-token>"),
    (r"glpat-[A-Za-z0-9_-]{20,}",  "<redacted:gitlab-token>"),
    (r"[0-9]{8,12}:AA[A-Za-z0-9_-]{30,}", "<redacted:telegram-token>"),
]
out = text
for p, r in subs:
    out = re.sub(p, r, out)
if out != text:
    # Back up once.
    bak = f.with_suffix(f.suffix + ".bak")
    if not bak.exists():
        bak.write_text(text)
    f.write_text(out)
    print(f"redacted {f} ({len(text)-len(out):+d} bytes); backup at {bak}")
else:
    print(f"{f}: nothing to redact")
PY
}

if [[ -n "$REDACT_TARGET" ]]; then
  redact_file "$REDACT_TARGET"
  exit 0
fi

# --- Scan ------------------------------------------------------------------

HITS=0
summary=""
echo "scanning: ${TARGETS[*]}"
echo "excludes: ${EXCLUDES[*]}${SCAN_ALL:+ (plus cache/, logs/ INCLUDED)}"
echo

for entry in "${PATTERNS[@]}"; do
  label="${entry%%|*}"
  regex="${entry#*|}"
  # rg --pcre2 is optional on older macOS; fall back to grep -E if rg absent.
  if command -v rg >/dev/null 2>&1; then
    matches=$(rg --pcre2 --no-messages --color=never -n \
      "${excl_args[@]}" -e "$regex" "${TARGETS[@]}" 2>/dev/null || true)
  else
    matches=$(grep -rEn --color=never \
      --exclude-dir=cache --exclude-dir=logs --exclude-dir=.git \
      --exclude='*.example.json' --exclude='secrets.env.example' \
      --exclude='AUDIT-identity-strings.md' --exclude='CHANGELOG.md' \
      --exclude='SKILL.md' --exclude='config.json' --exclude='secrets.env' \
      --exclude='sanitize-cache.sh' --exclude='doctor.sh' \
      "$regex" "${TARGETS[@]}" 2>/dev/null || true)
  fi
  # Filter out legacy root-level SETUP.md (docs/SETUP.md is kept).
  matches=$(printf "%s\n" "$matches" | grep -vE '^\./SETUP\.md:' || true)
  if [[ -n "$matches" ]]; then
    count=$(printf "%s\n" "$matches" | wc -l | tr -d ' ')
    HITS=$((HITS + count))
    summary+="  ${label}: ${count} hit(s)"$'\n'
    echo "[$label]"
    echo "$matches" | head -20
    [[ "$count" -gt 20 ]] && echo "  ... and $((count-20)) more"
    echo
  fi
done

if (( HITS == 0 )); then
  echo "clean — no PII / token patterns found"
  exit 0
fi

echo "--- summary ---"
printf "%s" "$summary"
echo "total: $HITS matches"
echo
echo "Next steps:"
echo "  - review each file; move real data into cache/ or logs/ (gitignored)"
echo "  - if false positives, add exclude in bin/sanitize-cache.sh PATTERNS"
echo "  - to auto-redact: bin/sanitize-cache.sh --redact <file>"
exit 1
