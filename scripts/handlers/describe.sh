#!/bin/bash
# handlers/describe.sh — Generate MR description from git diff + Jira ticket
#
# Usage: handler_describe <ticket_key>
#
# Finds the open MR for the ticket, gets the diff against the target branch,
# fetches the Jira ticket summary, and composes a concise MR description.
# Then offers buttons to apply it or copy it.

handler_describe() {
  local ticket="${1:-}"
  ticket=$(printf '%s' "$ticket" | tr '[:lower:]' '[:upper:]' | xargs)
  if [[ -z "$ticket" ]]; then
    tg_send "Usage: describe UA-XXX"
    return 0
  fi

  tg_send "Generating description for $ticket…"

  local result
  result=$(
    TK_KEY="$ticket" \
    JIRA_SITE="${JIRA_SITE:-}" \
    ATLASSIAN_EMAIL="${ATLASSIAN_EMAIL:-}" \
    ATLASSIAN_API_TOKEN="${ATLASSIAN_API_TOKEN:-}" \
    CONFIG_PATH="${CONFIG_FILE:-$SKILL_DIR/config.json}" \
    python3 <<'PYEOF'
import os, json, subprocess, urllib.request, base64, re

tk = os.environ["TK_KEY"]
jira_site = os.environ.get("JIRA_SITE", "")
email = os.environ.get("ATLASSIAN_EMAIL", "")
token = os.environ.get("ATLASSIAN_API_TOKEN", "")
config = json.load(open(os.environ["CONFIG_PATH"]))
_proj0 = (config.get("projects") or [{}])[0] if isinstance(config.get("projects"), list) else {}
repos = config.get("repositories") or _proj0.get("repositories") or {}

auth_b64 = base64.b64encode(f"{email}:{token}".encode()).decode()

def run(cmd, cwd=None, timeout=30):
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout, r.stderr

# 1) Find open MR
found = None
for slug, meta in repos.items():
    local = meta.get("localPath")
    if not local or not os.path.isdir(local): continue
    rc, out, err = run(["glab", "mr", "list", "--search", tk, "--state", "opened", "--output", "json"], cwd=local)
    try: mrs = json.loads(out or "[]")
    except: mrs = []
    for m in mrs:
        if tk in (m.get("source_branch","") or "") or tk in (m.get("title","") or ""):
            found = {
                "repo": slug, "local": local,
                "project": meta.get("gitlabProject"),
                "iid": m.get("iid"),
                "source": m.get("source_branch"),
                "target": m.get("target_branch"),
                "web_url": m.get("web_url"),
            }
            break
    if found: break

if not found:
    print(f"No open MR found for {tk}")
    raise SystemExit(0)

# 2) Get Jira ticket summary + description
jira_summary = ""
jira_desc = ""
try:
    hdrs = {"Authorization": f"Basic {auth_b64}", "Content-Type": "application/json"}
    req = urllib.request.Request(f"{jira_site}/rest/api/3/issue/{tk}?fields=summary,description", headers=hdrs)
    resp = urllib.request.urlopen(req, timeout=10)
    data = json.loads(resp.read())
    jira_summary = data.get("fields", {}).get("summary", "")
    desc_doc = data.get("fields", {}).get("description") or {}
    # Flatten ADF to plain text
    def flatten_adf(node):
        if isinstance(node, str): return node
        if isinstance(node, dict):
            if node.get("type") == "text": return node.get("text", "")
            return " ".join(flatten_adf(c) for c in (node.get("content") or []))
        if isinstance(node, list):
            return " ".join(flatten_adf(c) for c in node)
        return ""
    jira_desc = flatten_adf(desc_doc).strip()[:500]
except Exception:
    pass

# 3) Get diff stats
run(["git", "fetch", "origin", found["target"]], cwd=found["local"], timeout=30)
rc, diff_stat, _ = run(["git", "diff", "--stat", f"origin/{found['target']}...HEAD"], cwd=found["local"])
rc, diff_names, _ = run(["git", "diff", "--name-only", f"origin/{found['target']}...HEAD"], cwd=found["local"])
rc, log_out, _ = run(["git", "log", "--oneline", f"origin/{found['target']}..HEAD"], cwd=found["local"])

files = [f for f in diff_names.strip().split("\n") if f.strip()] if diff_names.strip() else []
commits = [c for c in log_out.strip().split("\n") if c.strip()] if log_out.strip() else []

# 4) Categorize changes
categories = {}
for f in files:
    if "test" in f.lower() or "spec" in f.lower():
        categories.setdefault("Tests", []).append(f)
    elif f.endswith((".vue", ".tsx", ".jsx")):
        categories.setdefault("Components", []).append(f)
    elif f.endswith((".ts", ".js")):
        categories.setdefault("Logic", []).append(f)
    elif f.endswith((".css", ".scss", ".less")):
        categories.setdefault("Styles", []).append(f)
    elif f.endswith((".md", ".txt")):
        categories.setdefault("Docs", []).append(f)
    else:
        categories.setdefault("Other", []).append(f)

# 5) Compose description
parts = []
parts.append(f"MR description for {tk}: !{found['iid']}")
parts.append(f"Jira: {jira_summary}")
parts.append("")

# Summarize from commits
parts.append("Changes:")
for c in commits[:10]:
    sha, *msg_parts = c.split(" ", 1)
    msg = msg_parts[0] if msg_parts else ""
    parts.append(f"  • {msg}")
if len(commits) > 10:
    parts.append(f"  … and {len(commits)-10} more commits")

parts.append("")
parts.append(f"Files: {len(files)} changed")
for cat, cat_files in categories.items():
    parts.append(f"  {cat}: {len(cat_files)}")

# Generate copy-ready bullet list for MR description
parts.append("")
parts.append("— Copy-ready MR description —")
for c in commits[:6]:
    sha, *msg_parts = c.split(" ", 1)
    msg = msg_parts[0] if msg_parts else ""
    # Strip conventional commit prefix for cleaner bullets
    clean = re.sub(r'^(feat|fix|chore|refactor|test|docs|style)\([^)]*\):\s*', '', msg)
    clean = re.sub(r'^(feat|fix|chore|refactor|test|docs|style):\s*', '', clean)
    if clean:
        parts.append(f"- {clean[0].upper()}{clean[1:]}")

print("\n".join(parts))
PYEOF
  )

  if [[ -n "$result" ]]; then
    tg_send "$result"
  else
    tg_send "Failed to generate description for $ticket."
  fi
}
