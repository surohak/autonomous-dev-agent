#!/bin/bash
# bin/release.sh — semantic-version release driver.
#
# Automates the chores that accompany cutting a tag:
#   1. Refuse to run unless the working tree is clean and on the default
#      branch (override with --force).
#   2. Run the offline test suite; refuse to release if anything fails
#      (override with --skip-tests — not recommended).
#   3. Compute the next version from the bump kind (patch|minor|major) or
#      honour an explicit version passed via --version X.Y.Z.
#   4. Promote the "Unreleased" section of CHANGELOG.md into a dated
#      "vX.Y.Z — YYYY-MM-DD" section and insert a fresh "Unreleased" stub.
#   5. git add/commit the CHANGELOG change with a conventional message.
#   6. Annotate and push the tag.
#   7. If `gh` is available, open a draft GitHub Release with the section
#      contents as the body. The user is still expected to review + publish.
#
# Usage:
#   bin/release.sh patch
#   bin/release.sh minor
#   bin/release.sh major
#   bin/release.sh --version 0.4.0
#   bin/release.sh --dry-run patch      # preview only, no writes
#
# Intentionally NOT automatic: no npm/pip publish, no tweet, no push force.
# Anything mutative is printed first and requires explicit confirmation.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SKILL_DIR"

# --- args -----------------------------------------------------------------
BUMP=""
EXPLICIT_VERSION=""
DRY_RUN=0
FORCE=0
SKIP_TESTS=0

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    patch|minor|major) BUMP="$1"; shift ;;
    --version)         EXPLICIT_VERSION="$2"; shift 2 ;;
    --dry-run)         DRY_RUN=1; shift ;;
    --force)           FORCE=1; shift ;;
    --skip-tests)      SKIP_TESTS=1; shift ;;
    -h|--help)         usage ;;
    *)                 echo "unknown arg: $1"; usage ;;
  esac
done

[[ -z "$BUMP" && -z "$EXPLICIT_VERSION" ]] && usage

# --- helpers --------------------------------------------------------------
say() { echo "release: $*"; }
die() { echo "release: $*" >&2; exit 1; }

run() {
  if [[ "$DRY_RUN" = "1" ]]; then
    echo "DRY  $*"
  else
    eval "$@"
  fi
}

# --- preflight -------------------------------------------------------------
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  die "not in a git working tree"
fi

if (( FORCE == 0 )); then
  if ! git diff --quiet HEAD -- . ':(exclude)logs/' ':(exclude)cache/'; then
    die "working tree has uncommitted changes. Commit or stash first, or pass --force."
  fi
  default_branch=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|origin/||' || true)
  default_branch="${default_branch:-main}"
  current_branch=$(git branch --show-current)
  if [[ "$current_branch" != "$default_branch" ]]; then
    die "expected to be on '$default_branch' but on '$current_branch'. Switch or pass --force."
  fi
fi

if (( SKIP_TESTS == 0 )); then
  say "running offline test suite…"
  if ! bash scripts/tests/run-tests.sh >/tmp/release-tests.$$ 2>&1; then
    cat /tmp/release-tests.$$ >&2
    rm -f /tmp/release-tests.$$
    die "tests failed — refusing to release (override with --skip-tests at your peril)"
  fi
  rm -f /tmp/release-tests.$$
  say "tests green"
fi

# --- figure out the next version ------------------------------------------
# Pull the latest tag that looks like vX.Y.Z. If none exists, assume 0.0.0.
current_tag=$(git tag --list 'v*.*.*' --sort=-v:refname | head -n1)
current_version="${current_tag#v}"
current_version="${current_version:-0.0.0}"

if [[ -n "$EXPLICIT_VERSION" ]]; then
  next_version="$EXPLICIT_VERSION"
  # Strip leading v just in case the user typed one.
  next_version="${next_version#v}"
else
  IFS=. read -r MAJ MIN PAT <<<"$current_version"
  case "$BUMP" in
    patch) PAT=$((PAT + 1)) ;;
    minor) MIN=$((MIN + 1)); PAT=0 ;;
    major) MAJ=$((MAJ + 1)); MIN=0; PAT=0 ;;
  esac
  next_version="${MAJ}.${MIN}.${PAT}"
fi

# Sanity: next must be semver-ish.
[[ "$next_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]] \
  || die "next version '$next_version' is not semver"

# Sanity: must not regress.
# shellcheck disable=SC2046
if [[ "$current_version" != "0.0.0" ]]; then
  smallest=$(printf '%s\n%s\n' "$current_version" "$next_version" | sort -V | head -n1)
  if [[ "$smallest" != "$current_version" ]]; then
    die "next version ($next_version) is not greater than current ($current_version)"
  fi
fi

say "current:    v${current_version}"
say "next:       v${next_version}"

# --- CHANGELOG rewrite -----------------------------------------------------
[[ -f CHANGELOG.md ]] || die "CHANGELOG.md missing"

today=$(date +%Y-%m-%d)
tmp_changelog=$(mktemp)

python3 - "$next_version" "$today" > "$tmp_changelog" <<'PY'
import re, sys
version, today = sys.argv[1], sys.argv[2]

with open("CHANGELOG.md") as f:
    src = f.read()

# Grab Unreleased block (everything between "## [Unreleased]" and the next "## ")
m = re.search(r"(## \[Unreleased\][^\n]*\n)(.*?)(?=\n## |\Z)", src, re.DOTALL)
if not m:
    print(src, end="")
    sys.exit(0)

header, body = m.group(1), m.group(2).strip()
if not body:
    body = "_(no changes recorded — release script refuses to promote an empty Unreleased)_"
    print(src, end="")
    sys.exit(2)  # signal caller to abort

new_section = f"## [{version}] — {today}\n\n{body}\n\n"
new_unreleased = "## [Unreleased]\n\n"
replacement = new_unreleased + new_section
out = src.replace(m.group(0), replacement, 1)
print(out, end="")
PY
py_rc=$?
if (( py_rc == 2 )); then
  die "CHANGELOG Unreleased section is empty — write some notes before releasing"
fi

if [[ "$DRY_RUN" = "1" ]]; then
  echo "--- CHANGELOG.md diff (preview) ---"
  diff -u CHANGELOG.md "$tmp_changelog" || true
  rm -f "$tmp_changelog"
else
  mv "$tmp_changelog" CHANGELOG.md
  git add CHANGELOG.md
  git commit -m "chore(release): v${next_version}"
fi

# --- tag + push ------------------------------------------------------------
tag="v${next_version}"
notes=$(python3 - "$next_version" <<'PY'
import re, sys
version = sys.argv[1]
with open("CHANGELOG.md") as f:
    src = f.read()
m = re.search(
    rf"## \[{re.escape(version)}\][^\n]*\n(.*?)(?=\n## |\Z)",
    src, re.DOTALL,
)
print((m.group(1) if m else "").strip())
PY
)

say "creating tag ${tag}…"
if [[ "$DRY_RUN" = "1" ]]; then
  echo "DRY  git tag -a ${tag} -m 'Release ${tag}'"
  echo "DRY  git push origin HEAD ${tag}"
  echo "--- release notes (preview) ---"
  echo "$notes"
  exit 0
fi

git tag -a "$tag" -m "Release $tag"
git push origin HEAD "$tag"

# --- GitHub Release (optional) --------------------------------------------
if command -v gh >/dev/null 2>&1; then
  say "creating draft GitHub Release…"
  printf '%s\n' "$notes" > /tmp/release-notes-$$.md
  if gh release create "$tag" \
      --title "$tag" \
      --notes-file /tmp/release-notes-$$.md \
      --draft; then
    say "draft release created — review it on GitHub and click Publish"
  else
    say "gh release create failed — you can publish from the GitHub UI manually"
  fi
  rm -f /tmp/release-notes-$$.md
else
  say "gh CLI not installed — create the GitHub Release manually from the tag"
fi

say "done — ${tag} is live"
