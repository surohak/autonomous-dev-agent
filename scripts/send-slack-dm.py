#!/usr/bin/env python3
"""Send a Slack DM using the OAuth token that Cursor IDE already has.

Why: the CLI `cursor-agent` can't load the Slack MCP (broken redirect_uri in
Cursor's Slack app configuration), and we don't want to maintain a separate
Slack bot token. The Cursor IDE has successfully completed the OAuth dance and
stored the access_token + refresh_token (encrypted) in its state database.

We decrypt those tokens with the same scheme Electron's safeStorage uses on
macOS (AES-128-CBC, key = PBKDF2-HMAC-SHA1(keychain_password, 'saltysalt', 1003,
16), IV = 16 spaces), then call Slack's Web API directly.

Usage:
    TK_KEY=PROJ-832 python3 send-slack-dm.py             # drain one task file
    ALL=1 python3 send-slack-dm.py                     # drain ALL pending tasks
    python3 send-slack-dm.py --channel <slack-user-id> --message "hi"  # ad hoc

Exit codes:
    0  success (at least one DM sent)
    2  nothing to do (empty queue)
    1  failure — stderr/stdout has the reason
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

SKILL_DIR = Path(os.environ.get("SKILL_DIR") or
                 (Path.home() / ".cursor" / "skills" / "autonomous-dev-agent"))
CACHE_DIR = Path(os.environ.get("CACHE_DIR") or (SKILL_DIR / "cache"))
# Pending-DM queue is per-project in v0.3; fall back to the legacy flat
# location when the env var isn't set (e.g. when invoked standalone).
PENDING_DIR = Path(os.environ.get("PENDING_DM_DIR") or (CACHE_DIR / "pending-dm"))
SENT_DIR = PENDING_DIR / "sent"
TOKEN_CACHE = Path(os.environ.get("SLACK_TOKEN_FILE") or (CACHE_DIR / "slack-token.json"))

CURSOR_DB = (Path.home() / "Library" / "Application Support" / "Cursor"
             / "User" / "globalStorage" / "state.vscdb")
SLACK_MCP_KEY = ('secret://{"extensionId":"anysphere.cursor-mcp",'
                 '"key":"[plugin-slack-slack] mcp_tokens"}')
SLACK_CI_KEY = ('secret://{"extensionId":"anysphere.cursor-mcp",'
                '"key":"[plugin-slack-slack] mcp_client_information"}')

SLACK_API = "https://slack.com/api"


# ---------- Cursor state decryption ----------

def _keychain_password() -> str:
    r = subprocess.run(
        ["security", "find-generic-password", "-w", "-s", "Cursor Safe Storage"],
        capture_output=True, text=True, timeout=15,
    )
    if r.returncode != 0 or not r.stdout.strip():
        raise RuntimeError("keychain: cannot read 'Cursor Safe Storage' "
                           f"(rc={r.returncode}, err={r.stderr.strip()[:200]})")
    return r.stdout.strip()


def _decrypt_safestorage(buf: bytes) -> bytes:
    if buf[:3] != b"v10":
        raise RuntimeError(f"unexpected safeStorage prefix: {buf[:4]!r}")
    ciphertext = buf[3:]
    pw = _keychain_password()
    key = hashlib.pbkdf2_hmac("sha1", pw.encode(), b"saltysalt", 1003, 16)
    iv = b"\x20" * 16
    # openssl enc -d -aes-128-cbc -K <key> -iv <iv>
    r = subprocess.run(
        ["openssl", "enc", "-d", "-aes-128-cbc",
         "-K", key.hex(), "-iv", iv.hex()],
        input=ciphertext, capture_output=True, timeout=10,
    )
    if r.returncode != 0:
        raise RuntimeError(f"openssl decrypt failed: {r.stderr.decode()[:200]}")
    return r.stdout


def _read_cursor_secret(db: Path, key: str) -> dict:
    if not db.exists():
        raise RuntimeError(f"cursor db not found: {db}")
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=5)
    try:
        row = con.execute(
            "SELECT value FROM ItemTable WHERE key = ?", (key,)
        ).fetchone()
    finally:
        con.close()
    if not row:
        raise RuntimeError(f"cursor secret missing: {key[:80]}…")
    obj = json.loads(row[0])
    buf = bytes(obj["data"])
    pt = _decrypt_safestorage(buf)
    return json.loads(pt.decode("utf-8"))


def _load_slack_credentials() -> dict:
    """Return {'access_token', 'refresh_token', 'scope', 'client_id'}.

    Uses a short-lived on-disk cache (cache/slack-token.json) to avoid a
    Keychain prompt on every DM. Cache expires 5 min before the token expires.
    """
    now = int(time.time())
    if TOKEN_CACHE.exists():
        try:
            cached = json.loads(TOKEN_CACHE.read_text())
            if cached.get("expires_at", 0) > now + 30:
                return cached
        except Exception:
            pass
    tokens = _read_cursor_secret(CURSOR_DB, SLACK_MCP_KEY)
    client = _read_cursor_secret(CURSOR_DB, SLACK_CI_KEY)
    creds = {
        "access_token":  tokens["access_token"],
        "refresh_token": tokens.get("refresh_token", ""),
        "scope":         tokens.get("scope", ""),
        "token_type":    tokens.get("token_type", "Bearer"),
        "expires_at":    now + int(tokens.get("expires_in", 43200)) - 60,
        "client_id":     client["client_id"],
    }
    try:
        TOKEN_CACHE.parent.mkdir(parents=True, exist_ok=True)
        TOKEN_CACHE.write_text(json.dumps(creds))
        os.chmod(TOKEN_CACHE, 0o600)
    except Exception:
        pass
    return creds


# ---------- Slack calls ----------

def _slack_post(endpoint: str, fields: dict, token: str) -> dict:
    body = urllib.parse.urlencode(fields).encode()
    req = urllib.request.Request(
        f"{SLACK_API}/{endpoint}",
        data=body,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/x-www-form-urlencoded; charset=utf-8",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        return {"ok": False, "error": f"http_{e.code}", "body": e.read().decode()[:400]}
    except Exception as e:
        return {"ok": False, "error": "request_failed", "body": str(e)[:400]}


def _refresh_access_token(creds: dict) -> dict | None:
    """PKCE public-client refresh. Writes new token back to the cache file (not to
    Cursor's DB — the IDE will refresh its own copy next time it's used)."""
    if not creds.get("refresh_token") or not creds.get("client_id"):
        return None
    r = _slack_post("oauth.v2.access", {
        "grant_type":    "refresh_token",
        "refresh_token": creds["refresh_token"],
        "client_id":     creds["client_id"],
    }, token="")  # no auth header for token endpoint (PKCE public client)
    if not r.get("ok"):
        return None
    now = int(time.time())
    new = dict(creds)
    new["access_token"]  = r.get("authed_user", {}).get("access_token") or r["access_token"]
    new["refresh_token"] = r.get("authed_user", {}).get("refresh_token") or r.get("refresh_token", creds["refresh_token"])
    new["expires_at"]    = now + int(r.get("authed_user", {}).get("expires_in")
                                     or r.get("expires_in", 43200)) - 60
    try:
        TOKEN_CACHE.write_text(json.dumps(new))
        os.chmod(TOKEN_CACHE, 0o600)
    except Exception:
        pass
    return new


def _send_dm(channel_id: str, message: str) -> tuple[bool, str, dict]:
    creds = _load_slack_credentials()
    r = _slack_post("chat.postMessage", {
        "channel": channel_id,
        "text":    message,
    }, creds["access_token"])
    if r.get("ok"):
        return True, "", r
    # Retry once after refresh if auth-related
    if r.get("error") in ("invalid_auth", "token_expired", "not_authed"):
        fresh = _refresh_access_token(creds)
        if fresh:
            r = _slack_post("chat.postMessage", {
                "channel": channel_id, "text": message,
            }, fresh["access_token"])
            if r.get("ok"):
                return True, "", r
    return False, r.get("error") or "unknown", r


# ---------- queue + notifications ----------

def _notify_telegram(text: str) -> None:
    try:
        env = {}
        for line in (SKILL_DIR / "secrets.env").read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
        tok = env.get("TELEGRAM_BOT_TOKEN")
        chat = env.get("TELEGRAM_CHAT_ID")
        if not tok or not chat:
            return
        body = json.dumps({"chat_id": int(chat), "text": text}).encode()
        req = urllib.request.Request(
            f"https://api.telegram.org/bot{tok}/sendMessage",
            data=body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        urllib.request.urlopen(req, timeout=10).read()
    except Exception:
        pass


def _drain(task_path: Path) -> int:
    try:
        task = json.loads(task_path.read_text())
    except Exception as e:
        print(f"ERR: cannot read {task_path.name}: {e}", file=sys.stderr)
        return 1
    tk = task.get("ticket_key") or task_path.stem
    channel = task.get("slack_user_id")
    message = task.get("message")
    approver = task.get("approver_name", "approver")
    if not channel or not message:
        print(f"ERR: {task_path.name}: missing slack_user_id or message", file=sys.stderr)
        return 1
    ok, err, resp = _send_dm(channel, message)
    if not ok:
        _notify_telegram(f"Agent: DM failed for {tk} — {err}")
        print(f"ERR: {tk}: slack error '{err}' (detail: {str(resp)[:200]})", file=sys.stderr)
        return 1
    # move to sent/
    SENT_DIR.mkdir(parents=True, exist_ok=True)
    task["sent_at"] = int(time.time())
    task["slack_ts"] = resp.get("ts")
    task["slack_channel"] = resp.get("channel")
    task["slack_message_link"] = resp.get("message", {}).get("permalink") or ""
    sent_path = SENT_DIR / f"{tk}-{task['sent_at']}.json"
    sent_path.write_text(json.dumps(task, indent=2))
    try:
        task_path.unlink()
    except Exception:
        pass
    _notify_telegram(f"Agent: DM sent to {approver} for {tk}")
    print(f"OK: {tk} -> {channel} (ts={resp.get('ts')})")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ticket",  help="Process only cache/pending-dm/<TICKET>.json")
    ap.add_argument("--all",     action="store_true", help="Drain the whole queue")
    ap.add_argument("--channel", help="Ad-hoc: Slack channel/user ID")
    ap.add_argument("--message", help="Ad-hoc: message body")
    args = ap.parse_args()

    # Env shortcuts used by the Telegram handler
    if not args.ticket and os.environ.get("TK_KEY"):
        args.ticket = os.environ["TK_KEY"]
    if os.environ.get("ALL") == "1":
        args.all = True

    if args.channel and args.message:
        ok, err, resp = _send_dm(args.channel, args.message)
        if ok:
            print(f"OK: {args.channel} (ts={resp.get('ts')})")
            return 0
        print(f"ERR: {err} ({str(resp)[:200]})", file=sys.stderr)
        return 1

    PENDING_DIR.mkdir(parents=True, exist_ok=True)

    if args.all:
        tasks = sorted(p for p in PENDING_DIR.glob("*.json"))
        if not tasks:
            print("INFO: queue is empty")
            return 2
        rc = 0
        for p in tasks:
            rc = _drain(p) or rc
        return rc

    if args.ticket:
        p = PENDING_DIR / f"{args.ticket}.json"
        if not p.exists():
            print(f"INFO: no queued task for {args.ticket}")
            return 2
        return _drain(p)

    ap.error("specify --ticket / --all / --channel + --message")


if __name__ == "__main__":
    sys.exit(main())
