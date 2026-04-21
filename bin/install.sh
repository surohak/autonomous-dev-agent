#!/bin/bash
# bin/install.sh — one-shot installer for autonomous-dev-agent.
#
# What it does:
#   1. Validates host prereqs (bash4+, python3, jq, curl, glab, cursor CLI).
#   2. Copies (or symlinks) this repo into $SKILL_DIR (default
#      ~/.cursor/skills/autonomous-dev-agent) so the Cursor IDE skill system
#      picks it up.
#   3. Calls bin/init.sh if config.json/secrets.env are missing, so the user
#      gets an interactive setup on first run.
#   4. Renders SKILL.md from SKILL.md.template using live config values.
#   5. Generates launchd plists from scripts/launchd/*.template and loads
#      (or reloads) them so the agent starts running immediately.
#
# Safe to re-run: every step is idempotent. Use `bin/install.sh --dev` to
# symlink the repo into $SKILL_DIR instead of copying, so edits in the
# checkout affect the running skill immediately (useful during development).

set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 [--dev] [--skip-launchd] [--skip-init] [--skip-swiftbar]

  --dev           Symlink this checkout into ~/.cursor/skills/ instead of copy.
  --skip-launchd  Don't generate/load plists (handy for CI + Docker tests).
  --skip-init     Don't run bin/init.sh even if config.json is missing.
  --skip-swiftbar Don't install the SwiftBar menu-bar plugin even if SwiftBar
                  is detected. (By default the plugin is linked only when
                  ~/Library/Application Support/SwiftBar/Plugins/ exists.)
  -h, --help      Show this help.
EOF
}

DEV_MODE=0
SKIP_LAUNCHD=0
SKIP_INIT=0
SKIP_SWIFTBAR=0
for arg in "$@"; do
  case "$arg" in
    --dev)           DEV_MODE=1 ;;
    --skip-launchd)  SKIP_LAUNCHD=1 ;;
    --skip-init)     SKIP_INIT=1 ;;
    --skip-swiftbar) SKIP_SWIFTBAR=1 ;;
    -h|--help)       usage; exit 0 ;;
    *)               echo "Unknown arg: $arg"; usage; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_DIR="${SKILL_DIR:-$HOME/.cursor/skills/autonomous-dev-agent}"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
LABEL_PREFIX="com.${USER:-user}"

echo "=== autonomous-dev-agent install ==="
echo "  repo     : $REPO_ROOT"
echo "  target   : $SKILL_DIR"
echo "  mode     : $([[ $DEV_MODE == 1 ]] && echo symlink || echo copy)"
echo

# -- Step 1 — prereqs --------------------------------------------------------
echo "[1/6] Checking prerequisites..."
missing=0
need() {
  local bin="$1" hint="$2"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "  MISSING: $bin  ($hint)"
    missing=1
  else
    echo "  OK     : $bin ($(command -v "$bin"))"
  fi
}
need python3 "brew install python"
need jq      "brew install jq"
need curl    "already on macOS"
need glab    "brew install glab   # GitLab CLI"
need cursor  "install Cursor IDE + enable the CLI"

# bash 4+ for associative arrays in handlers (macOS ships 3.2 as /bin/bash,
# but we shebang /bin/bash and avoid assoc arrays so that's fine; still warn).
bash_major=$(bash -c 'echo "${BASH_VERSION%%.*}"')
if [[ "$bash_major" -lt 3 ]]; then
  echo "  WARN   : bash $bash_major is very old — 3.2+ required"
fi

[[ $missing == 1 ]] && { echo; echo "Fix the missing tools above, then re-run."; exit 1; }
echo

# -- Step 2 — place files at $SKILL_DIR -------------------------------------
echo "[2/6] Deploying files to $SKILL_DIR..."
if [[ "$REPO_ROOT" == "$SKILL_DIR" ]]; then
  echo "  already installed in place, skipping copy"
elif [[ -L "$SKILL_DIR" ]]; then
  existing_target="$(readlink "$SKILL_DIR")"
  if [[ "$existing_target" == "$REPO_ROOT" ]]; then
    echo "  symlink already points to this repo"
  else
    echo "  WARN: $SKILL_DIR is a symlink to $existing_target"
    echo "        Not overwriting — remove it manually if you want this repo instead."
  fi
elif [[ -d "$SKILL_DIR" && $DEV_MODE == 0 ]]; then
  # Preserve config/secrets/cache/logs; rsync everything else.
  rsync -a --delete \
    --exclude='.git/' \
    --exclude='config.json' --exclude='secrets.env' \
    --exclude='cache/' --exclude='logs/' --exclude='SKILL.md' \
    "$REPO_ROOT/" "$SKILL_DIR/"
  echo "  rsynced (preserving config/secrets/cache/logs)"
elif [[ $DEV_MODE == 1 ]]; then
  mkdir -p "$(dirname "$SKILL_DIR")"
  ln -sfn "$REPO_ROOT" "$SKILL_DIR"
  echo "  symlinked $SKILL_DIR -> $REPO_ROOT"
else
  mkdir -p "$(dirname "$SKILL_DIR")"
  cp -R "$REPO_ROOT" "$SKILL_DIR"
  echo "  copied repo contents"
fi

mkdir -p "$SKILL_DIR/cache" "$SKILL_DIR/logs"
chmod +x "$SKILL_DIR"/bin/*.sh 2>/dev/null || true
chmod +x "$SKILL_DIR"/scripts/*.sh 2>/dev/null || true
chmod +x "$SKILL_DIR"/scripts/handlers/*.sh 2>/dev/null || true
chmod +x "$SKILL_DIR"/scripts/tests/*.sh 2>/dev/null || true
echo

# -- Step 3 — bootstrap config+secrets --------------------------------------
echo "[3/6] Config + secrets..."
if [[ ! -f "$SKILL_DIR/config.json" || ! -f "$SKILL_DIR/secrets.env" ]]; then
  if [[ $SKIP_INIT == 1 ]]; then
    echo "  config.json or secrets.env missing — skipping init (--skip-init)"
    echo "  Run '$SKILL_DIR/bin/init.sh' manually before loading launchd services."
  else
    echo "  running interactive wizard..."
    SKILL_DIR="$SKILL_DIR" bash "$SKILL_DIR/bin/init.sh"
  fi
else
  echo "  existing config.json + secrets.env — leaving untouched"
fi
echo

# -- Step 4 — render SKILL.md from template ---------------------------------
echo "[4/6] Rendering SKILL.md from template..."
if [[ -f "$SKILL_DIR/SKILL.md.template" && -f "$SKILL_DIR/config.json" ]]; then
  (
    cd "$SKILL_DIR"
    # shellcheck disable=SC1091
    source scripts/lib/env.sh
    # shellcheck disable=SC1091
    source scripts/lib/cfg.sh
    # shellcheck disable=SC1091
    source scripts/lib/prompt.sh
    prompt_render SKILL.md.template > SKILL.md
  )
  echo "  rendered $SKILL_DIR/SKILL.md"
else
  echo "  skipped (template or config not present)"
fi
echo

# -- Step 5 — launchd plists ------------------------------------------------
if [[ $SKIP_LAUNCHD == 1 ]]; then
  echo "[5/6] Skipping launchd setup (--skip-launchd)"
  echo
  echo "Install complete. Load launchd services manually later with:"
  echo "  bash $SKILL_DIR/bin/install.sh   (re-run without --skip-launchd)"
  exit 0
fi

echo "[5/6] Generating + loading launchd plists..."
mkdir -p "$LAUNCH_AGENTS"

render_plist() {
  local template="$1" out="$2"
  python3 - "$template" "$out" <<'PY'
import os, sys
tmpl, out = sys.argv[1], sys.argv[2]
text = open(tmpl).read()
subs = {
    "{{LAUNCHD_LABEL_PREFIX}}": f"com.{os.environ.get('USER','user')}",
    "{{SKILL_DIR}}":            os.environ["SKILL_DIR"],
    "{{HOME}}":                 os.environ["HOME"],
    "{{DIGEST_HOUR}}":          os.environ.get("DIGEST_HOUR",   "16"),
    "{{DIGEST_MINUTE}}":        os.environ.get("DIGEST_MINUTE", "0"),
    "{{PROJECT_SUFFIX}}":       os.environ.get("PROJECT_SUFFIX", ""),
    "{{AGENT_PROJECT}}":        os.environ.get("AGENT_PROJECT", ""),
}
for k, v in subs.items():
    text = text.replace(k, v)
open(out, "w").write(text)
PY
}

reload_plist() {
  local label="$1" path="$2"
  local uid domain
  uid="$(id -u)"
  domain="gui/$uid"

  # Modern API first (bootout+bootstrap) — gives clean domain semantics.
  launchctl bootout "$domain/$label" 2>/dev/null || true
  if launchctl bootstrap "$domain" "$path" 2>/tmp/adev-install.err; then
    echo "  loaded  : $label"
    return 0
  fi
  local bootstrap_err
  bootstrap_err="$(cat /tmp/adev-install.err 2>/dev/null || true)"

  # Legacy API fallback (older macOS / GUI-less contexts).
  launchctl unload "$path" 2>/dev/null || true
  if launchctl load "$path" 2>/tmp/adev-install.err; then
    echo "  loaded  : $label (via legacy load)"
    return 0
  fi

  # Both failed — surface what launchd actually said so users aren't left
  # staring at "Input/output error". The most common real cause is that
  # StandardOutPath / StandardErrorPath directories don't exist or aren't
  # writable, or that launchctl is running in a restricted context (e.g.
  # SSH session without a GUI domain, or a sandboxed IDE terminal).
  echo "  FAILED  : $label" >&2
  echo "            bootstrap: ${bootstrap_err:-(no stderr)}" >&2
  echo "            load:      $(cat /tmp/adev-install.err 2>/dev/null)" >&2
  echo "            Retry from a Terminal.app shell (not a sandboxed IDE shell):" >&2
  echo "              launchctl bootstrap $domain \"$path\"" >&2
  rm -f /tmp/adev-install.err
  return 1
}

# Read digest time from config.json if present.
if [[ -f "$SKILL_DIR/config.json" ]]; then
  export DIGEST_HOUR=$(python3 -c "import json;c=json.load(open('$SKILL_DIR/config.json'));t=c.get('time',{}).get('dailyDigest','16:00');print(t.split(':')[0])" 2>/dev/null || echo 16)
  export DIGEST_MINUTE=$(python3 -c "import json;c=json.load(open('$SKILL_DIR/config.json'));t=c.get('time',{}).get('dailyDigest','16:00');print(t.split(':')[1])" 2>/dev/null || echo 0)
fi

# The non-telegram services are single-instance — one plist each regardless of
# project count. The watcher already iterates all projects internally.
declare -a services=(
  "agent    autonomous-dev-agent"
  "watcher  dev-agent-watcher"
  "digest   dev-agent-digest"
)
for svc in "${services[@]}"; do
  name="${svc%% *}"
  label="${LABEL_PREFIX}.${svc##* }"
  tmpl="$SKILL_DIR/scripts/launchd/${name}.plist.template"
  plist="$LAUNCH_AGENTS/${label}.plist"
  [[ -f "$tmpl" ]] || { echo "  missing template: $tmpl"; continue; }
  SKILL_DIR="$SKILL_DIR" PROJECT_SUFFIX="" AGENT_PROJECT="" render_plist "$tmpl" "$plist"
  # Non-fatal: a reload failure (usually sandboxed-shell / domain issue) must not
  # abort the installer — render_plist already wrote the file to disk, and the
  # user can bootstrap it manually from Terminal. Crucially, aborting here would
  # skip subsequent services like the Telegram block below.
  reload_plist "$label" "$plist" || true
done

# -- Telegram plists: one per distinct bot token ----------------------------
# Each Telegram daemon long-polls exactly one bot, so multi-bot installs need
# one LaunchAgent per distinct token. install.sh groups projects by the env-var
# name that holds their token (chat.tokenEnv) and generates one plist per
# group, pinning it to the first project in that group via $AGENT_PROJECT.
#
# Single-bot installs still get a single plist labelled plainly (no suffix) so
# upgraders see zero behaviour change.
#
# Stale plists from previous installs (tokens no longer referenced) are
# unloaded + removed to avoid zombie daemons.
tg_tmpl="$SKILL_DIR/scripts/launchd/telegram.plist.template"
if [[ -f "$tg_tmpl" && -f "$SKILL_DIR/config.json" ]]; then
  # Produce "<project_id>\t<tokenEnv>" rows for each project. tokenEnv defaults
  # to TELEGRAM_BOT_TOKEN if chat.tokenEnv is unset anywhere in the cascade.
  # Use a temp file + while-read-loop (not `mapfile`) so this still runs on
  # macOS's default /bin/bash 3.2, which doesn't ship mapfile/readarray.
  tg_rows_file="$(mktemp -t adev-tg-rows.XXXXXX)"
  python3 - >"$tg_rows_file" 2>/dev/null <<'PY'
import json, os, sys
cfg = json.load(open(os.environ["SKILL_DIR"] + "/config.json"))
# Normalise v0.2 flat configs into a single "default" project on the fly.
if "projects" not in cfg:
    cfg = {"chat": cfg.get("chat", {}), "projects": [{"id": "default", "chat": cfg.get("chat", {})}]}
root_env = (cfg.get("chat") or {}).get("tokenEnv", "TELEGRAM_BOT_TOKEN")
for p in cfg["projects"]:
    env = ((p.get("chat") or {}).get("tokenEnv")) or root_env
    print(f"{p['id']}\t{env}")
PY
  tg_rows=()
  while IFS= read -r _row; do
    [[ -z "$_row" ]] && continue
    tg_rows+=("$_row")
  done < "$tg_rows_file"
  rm -f "$tg_rows_file"

  # bash 3.2 lacks associative arrays (declare -A), so track "seen tokenEnv"
  # in a simple newline-joined sentinel string and use case/glob matching.
  tg_seen=""
  tg_generated=()
  for row in "${tg_rows[@]}"; do
    pid="${row%%$'\t'*}"
    env_name="${row##*$'\t'}"
    # Pick the first project per env_name; subsequent duplicates share its daemon.
    case "$tg_seen" in
      *"<$env_name>"*) continue ;;
    esac
    tg_seen="$tg_seen<$env_name>"

    # Single-bot installs → no suffix, plain label (zero upgrade churn).
    if (( ${#tg_rows[@]} == 1 )); then
      suffix=""
    else
      # Sanitise: lowercase, non-[a-z0-9] → '-', collapse, strip edges.
      sanitised=$(echo "$pid" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//')
      suffix="-${sanitised:-default}"
    fi
    label="${LABEL_PREFIX}.dev-agent-telegram${suffix}"
    plist="$LAUNCH_AGENTS/${label}.plist"
    SKILL_DIR="$SKILL_DIR" PROJECT_SUFFIX="$suffix" AGENT_PROJECT="$pid" \
      render_plist "$tg_tmpl" "$plist"
    reload_plist "$label" "$plist" || true
    tg_generated+=("$label")
  done

  # Unload any stale telegram plists left over from previous installs.
  for old in "$LAUNCH_AGENTS"/"${LABEL_PREFIX}".dev-agent-telegram*.plist; do
    [[ -f "$old" ]] || continue
    old_label=$(basename "$old" .plist)
    keep=0
    for g in "${tg_generated[@]}"; do
      [[ "$old_label" == "$g" ]] && { keep=1; break; }
    done
    if (( keep == 0 )); then
      launchctl unload "$old" 2>/dev/null || true
      rm -f "$old"
      echo "  removed stale: $old_label"
    fi
  done
fi
echo

# -- Step 6 — optional SwiftBar menu-bar plugin -----------------------------
# Linked only when SwiftBar is already installed (plugins dir exists).
# Uses a symlink into the plugins dir so `git pull && bin/install.sh` picks
# up plugin edits without any extra step.
#
# SwiftBar lets users relocate the plugin directory (Preferences → General →
# Plugins Folder). We read that preference so installs don't silently no-op
# when the user picked a non-default location (a surprisingly common setup,
# e.g. ~/.config/swiftbar-plugins). Falls back to the default location, then
# to a couple of well-known alternate defaults.
SWIFTBAR_SRC="$SKILL_DIR/scripts/menubar/dev-agent.30s.sh"

detect_swiftbar_plugins() {
  # 1. Preference set by SwiftBar itself — authoritative if present.
  local pref
  pref=$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)
  if [[ -n "$pref" && -d "$pref" ]]; then
    echo "$pref"
    return 0
  fi
  # 2. Default Application Support location.
  if [[ -d "$HOME/Library/Application Support/SwiftBar/Plugins" ]]; then
    echo "$HOME/Library/Application Support/SwiftBar/Plugins"
    return 0
  fi
  # 3. Common XDG-style override seen in the wild.
  if [[ -d "$HOME/.config/swiftbar-plugins" ]]; then
    echo "$HOME/.config/swiftbar-plugins"
    return 0
  fi
  return 1
}

echo "[6/6] SwiftBar menu-bar plugin..."
if (( SKIP_SWIFTBAR == 1 )); then
  echo "  skipped (--skip-swiftbar)"
elif [[ ! -f "$SWIFTBAR_SRC" ]]; then
  echo "  plugin source missing: $SWIFTBAR_SRC"
else
  SWIFTBAR_PLUGINS=$(detect_swiftbar_plugins || true)
  if [[ -z "$SWIFTBAR_PLUGINS" ]]; then
    echo "  SwiftBar not detected — skipping"
    echo "  Install SwiftBar from https://swiftbar.app and re-run to enable the menu-bar icon."
    echo "  (If SwiftBar is installed but using a custom Plugins folder, run:"
    echo "     defaults write com.ameba.SwiftBar PluginDirectory \"/path/to/plugins\""
    echo "   from Terminal so the installer can find it.)"
  else
    SWIFTBAR_LINK="$SWIFTBAR_PLUGINS/dev-agent.30s.sh"
    # Replace any existing link/file so re-runs are idempotent.
    if [[ -L "$SWIFTBAR_LINK" || -f "$SWIFTBAR_LINK" ]]; then
      rm -f "$SWIFTBAR_LINK"
    fi
    ln -s "$SWIFTBAR_SRC" "$SWIFTBAR_LINK"
    chmod +x "$SWIFTBAR_SRC"
    echo "  plugins dir : $SWIFTBAR_PLUGINS"
    echo "  linked      : $SWIFTBAR_LINK -> $SWIFTBAR_SRC"
    echo "  Open SwiftBar (or run: open -a SwiftBar) to pick up the new plugin."
  fi
fi
echo

echo "Install complete."
echo "  Skill   : $SKILL_DIR"
echo "  Plists  : $LAUNCH_AGENTS/${LABEL_PREFIX}.*.plist"
echo
echo "Next steps:"
echo "  - Verify health : bash $SKILL_DIR/bin/doctor.sh"
echo "  - Tail logs     : tail -f $SKILL_DIR/logs/watcher.log"
echo "  - Telegram      : send /status to your bot"
