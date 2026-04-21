#!/bin/bash
# scripts/lib/rebase.sh — auto-rebase + safe auto-resolve on main drift.
#
# When the watcher sees an MR whose source branch is behind main, we want
# to rebase it automatically if the resulting diff is conflict-free (or
# conflicts only in trivially-resolvable ways: lock files, translation
# JSONs, generated docs). Anything risky stays out — we surface a
# Telegram card asking for human review.
#
# Usage:
#   rebase_check <local-repo-path> <source-branch> <target-branch>
#       → echoes JSON:  { "drift": true|false, "behind": N, "conflicts": [files], "safe": true|false }
#       → exit 0 on success, 2 on unusable repo, 3 on fatal git error
#   rebase_apply <local-repo-path> <source-branch> <target-branch>
#       → attempts `git rebase` with safe-auto-resolve for whitelisted
#         file patterns (configurable via projects[].rebase.autoResolve).
#       → echoes JSON:  { "applied": true|false, "rebased_to": "<sha>", "resolved": [files], "skipped": [files] }

[[ -n "${_DEV_AGENT_REBASE_LOADED:-}" ]] && return 0
_DEV_AGENT_REBASE_LOADED=1

# File patterns we will auto-resolve by taking the target-branch version
# ("ours" in rebase parlance is confusingly inverted — during rebase,
# HEAD is the target-branch tip, so --ours takes the main-branch version).
# Users can override/extend via projects[].rebase.autoResolve.
_REBASE_DEFAULT_AUTORESOLVE=(
  # Lock files — should always take the newer main version.
  "package-lock.json"
  "yarn.lock"
  "pnpm-lock.yaml"
  "Gemfile.lock"
  "poetry.lock"
  "Pipfile.lock"
  "composer.lock"
  "Cargo.lock"
  "go.sum"
  # Translation JSONs — main has freshest strings from crowdin-pull.
  "translations/*.json"
  "messages/*.json"
  "i18n/*.json"
  # CI-generated docs.
  "docs/generated/**"
)

_rebase_autoresolve_patterns() {
  local custom
  custom=$(cfg_get ".projects[] | select(.id==\"${AGENT_PROJECT:-}\") | .rebase.autoResolve[]?" "" 2>/dev/null)
  if [[ -n "$custom" ]]; then
    printf '%s\n' "$custom"
  fi
  printf '%s\n' "${_REBASE_DEFAULT_AUTORESOLVE[@]}"
}

_file_matches_any() {
  local file="$1"; shift
  local pat
  for pat in "$@"; do
    # Glob match using bash =~ after converting glob to regex, or use
    # bash globbing with `case`.
    case "$file" in
      $pat) return 0 ;;
    esac
  done
  return 1
}

rebase_check() {
  local repo="$1" src="$2" tgt="$3"
  [[ -d "$repo/.git" || -f "$repo/.git" ]] || { echo '{"drift":false}'; return 2; }

  (
    cd "$repo" || exit 2
    git fetch --quiet origin "$tgt" "$src" 2>/dev/null || exit 3

    # How far behind is src vs tgt?
    local behind
    behind=$(git rev-list --count "origin/$src..origin/$tgt" 2>/dev/null || echo 0)
    [[ "$behind" -eq 0 ]] && { echo '{"drift":false,"behind":0}'; exit 0; }

    # Detect potential conflicts by trying a 3-way merge-tree (dry run,
    # no working tree mutation). `git merge-tree` prints conflict markers
    # when there's overlap.
    local base
    base=$(git merge-base "origin/$src" "origin/$tgt" 2>/dev/null) || { echo '{"drift":true,"behind":'"$behind"',"conflicts":["<merge-base missing>"]}'; exit 0; }
    local mt
    mt=$(git merge-tree "$base" "origin/$src" "origin/$tgt" 2>/dev/null)

    # Parse conflicting file names from merge-tree output. Format:
    #   added in both
    #   our    100644 <sha> <file>
    #   their  100644 <sha> <file>
    #   @@ -... (conflict hunk)
    local conflicts
    conflicts=$(printf '%s' "$mt" | awk '
      /^changed in both|^added in both/ { reading=1; next }
      reading && /^  our[[:space:]]/ {
        n = split($0, a, " "); print a[n]
      }
    ' | sort -u)

    if [[ -z "$conflicts" ]]; then
      echo '{"drift":true,"behind":'"$behind"',"conflicts":[],"safe":true}'
      exit 0
    fi

    # Partition conflicts into safe vs unsafe using the project's
    # auto-resolve patterns.
    mapfile -t pats < <(_rebase_autoresolve_patterns)
    local safe_list=() unsafe_list=()
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      if _file_matches_any "$f" "${pats[@]}"; then
        safe_list+=("$f")
      else
        unsafe_list+=("$f")
      fi
    done <<< "$conflicts"

    local is_safe=false
    [[ ${#unsafe_list[@]} -eq 0 ]] && is_safe=true
    SAFE="$is_safe" BEHIND="$behind" \
      SAFE_LIST="$(printf '%s\n' "${safe_list[@]}")" \
      UNSAFE_LIST="$(printf '%s\n' "${unsafe_list[@]}")" \
      python3 -c '
import json, os
safe = os.environ["SAFE"] == "true"
behind = int(os.environ["BEHIND"])
sl = [x for x in os.environ.get("SAFE_LIST","").splitlines() if x]
ul = [x for x in os.environ.get("UNSAFE_LIST","").splitlines() if x]
print(json.dumps({
    "drift":        True,
    "behind":       behind,
    "conflicts":    sl + ul,
    "auto_resolve": sl,
    "manual":       ul,
    "safe":         safe
}))'
  )
}

rebase_apply() {
  local repo="$1" src="$2" tgt="$3"
  [[ -d "$repo/.git" || -f "$repo/.git" ]] || return 2

  local check
  check=$(rebase_check "$repo" "$src" "$tgt") || return $?
  local drift safe
  drift=$(printf '%s' "$check" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("drift"))')
  safe=$( printf '%s' "$check" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("safe"))')
  [[ "$drift" != "True" ]] && { echo '{"applied":false,"reason":"no drift"}'; return 0; }
  [[ "$safe"  != "True" ]] && { printf '{"applied":false,"reason":"unsafe conflicts","detail":%s}\n' "$check"; return 0; }

  (
    cd "$repo" || exit 2
    git fetch --quiet origin "$tgt" "$src" 2>/dev/null

    # Work on a scratch worktree so we don't disturb the user's checkout.
    local wtree
    wtree=$(mktemp -d -t rebase-wt.XXXXXX)
    git worktree add --detach "$wtree" "origin/$src" >/dev/null 2>&1 || { rm -rf "$wtree"; exit 3; }

    local rc=0
    (
      cd "$wtree" || exit 3
      git checkout -b "rebase-auto-$$" >/dev/null 2>&1 || exit 3

      # Run the rebase; auto-resolve patterns get `git checkout --theirs`
      # (take the main branch version) when git complains.
      if git rebase "origin/$tgt" >/dev/null 2>&1; then
        rc=0
      else
        # Conflicts — try to resolve.
        local conflict_files
        conflict_files=$(git diff --name-only --diff-filter=U)
        mapfile -t pats < <(_rebase_autoresolve_patterns)
        local all_resolved=true
        while IFS= read -r f; do
          [[ -z "$f" ]] && continue
          if _file_matches_any "$f" "${pats[@]}"; then
            git checkout --theirs -- "$f" >/dev/null 2>&1
            git add -- "$f" >/dev/null 2>&1
          else
            all_resolved=false
            break
          fi
        done <<< "$conflict_files"

        if ! $all_resolved; then
          git rebase --abort >/dev/null 2>&1
          exit 1
        fi

        if git -c core.editor=true rebase --continue >/dev/null 2>&1; then
          rc=0
        else
          git rebase --abort >/dev/null 2>&1
          exit 1
        fi
      fi

      # Push the rebased branch with --force-with-lease to stay safe against
      # concurrent pushes.
      if ! git push --force-with-lease origin "HEAD:$src" >/dev/null 2>&1; then
        exit 4
      fi
      rc=0
    )
    rc=$?

    local head_sha=""
    [[ -d "$wtree" ]] && head_sha=$(git -C "$wtree" rev-parse HEAD 2>/dev/null || echo "")
    git worktree remove --force "$wtree" >/dev/null 2>&1 || rm -rf "$wtree"

    case $rc in
      0) printf '{"applied":true,"rebased_to":"%s","detail":%s}\n' "$head_sha" "$check" ;;
      1) printf '{"applied":false,"reason":"conflicts during apply","detail":%s}\n' "$check" ;;
      4) printf '{"applied":false,"reason":"push rejected (force-with-lease)","detail":%s}\n' "$check" ;;
      *) printf '{"applied":false,"reason":"git error rc=%s","detail":%s}\n' "$rc" "$check" ;;
    esac
  )
}
