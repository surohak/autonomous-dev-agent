#!/usr/bin/env python3
"""Read Slack messages using the OAuth token that Cursor IDE already has.

Companion to send-slack-dm.py — shares the same Cursor safeStorage token
decryption. Provides three modes:

  --poll          Poll conversations.history on configured channels
  --thread C T    Read a full thread (conversations.replies)
  --download-files JSON_FILE OUT_DIR   Download Slack-hosted file attachments

Exit codes:
    0  success (JSON on stdout)
    1  failure
    3  token unavailable (Cursor not running, keychain locked, etc.)
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
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
TOKEN_CACHE = Path(os.environ.get("SLACK_TOKEN_FILE") or (CACHE_DIR / "slack-token.json"))

CURSOR_DB = (Path.home() / "Library" / "Application Support" / "Cursor"
             / "User" / "globalStorage" / "state.vscdb")
SLACK_MCP_KEY = ('secret://{"extensionId":"anysphere.cursor-mcp",'
                 '"key":"[plugin-slack-slack] mcp_tokens"}')
SLACK_CI_KEY = ('secret://{"extensionId":"anysphere.cursor-mcp",'
                '"key":"[plugin-slack-slack] mcp_client_information"}')

SLACK_API = "https://slack.com/api"


# ---------- Cursor state decryption (shared with send-slack-dm.py) ----------

def _keychain_password() -> str:
    r = subprocess.run(
        ["security", "find-generic-password", "-w", "-s", "Cursor Safe Storage"],
        capture_output=True, text=True, timeout=15,
    )
    if r.returncode != 0 or not r.stdout.strip():
        raise RuntimeError("keychain: cannot read 'Cursor Safe Storage'")
    return r.stdout.strip()


def _decrypt_safestorage(buf: bytes) -> bytes:
    if buf[:3] != b"v10":
        raise RuntimeError(f"unexpected safeStorage prefix: {buf[:4]!r}")
    ciphertext = buf[3:]
    pw = _keychain_password()
    key = hashlib.pbkdf2_hmac("sha1", pw.encode(), b"saltysalt", 1003, 16)
    iv = b"\x20" * 16
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


# ---------- Slack API calls ----------

def _slack_get(endpoint: str, params: dict, token: str) -> dict:
    qs = urllib.parse.urlencode(params)
    req = urllib.request.Request(
        f"{SLACK_API}/{endpoint}?{qs}",
        headers={"Authorization": f"Bearer {token}"},
        method="GET",
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        return {"ok": False, "error": f"http_{e.code}", "body": e.read().decode()[:400]}
    except Exception as e:
        return {"ok": False, "error": "request_failed", "body": str(e)[:400]}


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
    if not creds.get("refresh_token") or not creds.get("client_id"):
        return None
    r = _slack_post("oauth.v2.access", {
        "grant_type":    "refresh_token",
        "refresh_token": creds["refresh_token"],
        "client_id":     creds["client_id"],
    }, token="")
    if not r.get("ok"):
        return None
    now = int(time.time())
    new = dict(creds)
    new["access_token"] = (r.get("authed_user", {}).get("access_token")
                           or r["access_token"])
    new["refresh_token"] = (r.get("authed_user", {}).get("refresh_token")
                            or r.get("refresh_token", creds["refresh_token"]))
    new["expires_at"] = (now + int(r.get("authed_user", {}).get("expires_in")
                                   or r.get("expires_in", 43200)) - 60)
    try:
        TOKEN_CACHE.write_text(json.dumps(new))
        os.chmod(TOKEN_CACHE, 0o600)
    except Exception:
        pass
    return new


def _api_call(method: str, endpoint: str, params: dict, creds: dict) -> dict:
    """Call Slack API with auto-refresh on auth failure."""
    token = creds["access_token"]
    fn = _slack_get if method == "GET" else _slack_post
    r = fn(endpoint, params, token)
    if r.get("ok"):
        return r
    if r.get("error") in ("invalid_auth", "token_expired", "not_authed"):
        fresh = _refresh_access_token(creds)
        if fresh:
            creds.update(fresh)
            r = fn(endpoint, params, fresh["access_token"])
            if r.get("ok"):
                return r
    return r


# ---------- User resolution cache ----------

_user_cache: dict[str, str] = {}


def _resolve_user(user_id: str, creds: dict) -> str:
    if user_id in _user_cache:
        return _user_cache[user_id]
    r = _api_call("GET", "users.info", {"user": user_id}, creds)
    if r.get("ok"):
        profile = r.get("user", {})
        name = (profile.get("real_name")
                or profile.get("profile", {}).get("real_name")
                or profile.get("name")
                or user_id)
        _user_cache[user_id] = name
        return name
    _user_cache[user_id] = user_id
    return user_id


def _resolve_channel(channel_id: str, creds: dict) -> str:
    r = _api_call("GET", "conversations.info", {"channel": channel_id}, creds)
    if r.get("ok"):
        ch = r.get("channel", {})
        if ch.get("is_im"):
            return f"DM with {_resolve_user(ch.get('user', ''), creds)}"
        return f"#{ch.get('name', channel_id)}"
    return channel_id


# ---------- Message normalization ----------

def _normalize_msg(msg: dict, creds: dict) -> dict:
    """Extract a clean message dict from a Slack message object."""
    files = []
    for f in msg.get("files") or []:
        if f.get("mimetype", "").startswith("image/") or f.get("filetype") in (
            "png", "jpg", "jpeg", "gif", "webp", "bmp", "svg",
        ):
            url = f.get("url_private_download") or f.get("url_private") or ""
            if url:
                files.append({
                    "url": url,
                    "name": f.get("name", ""),
                    "mimetype": f.get("mimetype", ""),
                })
    return {
        "channel": msg.get("channel", ""),
        "ts": msg.get("ts", ""),
        "thread_ts": msg.get("thread_ts", ""),
        "user": msg.get("user", ""),
        "user_name": _resolve_user(msg.get("user", ""), creds),
        "text": msg.get("text", ""),
        "files": files,
    }


# ---------- Commands ----------

def cmd_poll(channels: list[str], oldest: str, creds: dict) -> list[dict]:
    results = []
    for ch in channels:
        params: dict = {"channel": ch, "limit": "30"}
        if oldest:
            params["oldest"] = oldest
        r = _api_call("GET", "conversations.history", params, creds)
        if not r.get("ok"):
            print(f"WARN: conversations.history failed for {ch}: "
                  f"{r.get('error', 'unknown')}", file=sys.stderr)
            continue
        for msg in r.get("messages", []):
            if msg.get("subtype") in ("channel_join", "channel_leave",
                                       "bot_message", "tombstone"):
                continue
            m = _normalize_msg(msg, creds)
            m["channel"] = ch
            results.append(m)
    results.sort(key=lambda m: float(m.get("ts", "0")))
    return results


def cmd_thread(channel: str, thread_ts: str, creds: dict) -> dict:
    r = _api_call("GET", "conversations.replies", {
        "channel": channel,
        "ts": thread_ts,
        "limit": "100",
    }, creds)
    if not r.get("ok"):
        return {"ok": False, "error": r.get("error", "unknown"),
                "channel": channel, "thread_ts": thread_ts, "messages": []}
    messages = []
    for msg in r.get("messages", []):
        m = _normalize_msg(msg, creds)
        m["channel"] = channel
        messages.append(m)
    return {
        "ok": True,
        "channel": channel,
        "channel_name": _resolve_channel(channel, creds),
        "thread_ts": thread_ts,
        "messages": messages,
    }


def cmd_download_files(file_list_path: str, out_dir: str, creds: dict) -> dict:
    """Download Slack-hosted files (images etc.) to a local directory."""
    token = creds["access_token"]
    file_list = json.loads(Path(file_list_path).read_text())
    Path(out_dir).mkdir(parents=True, exist_ok=True)

    downloaded = {}
    for i, f in enumerate(file_list):
        url = f.get("url", "")
        name = f.get("name", "") or f"file_{i}"
        if not url:
            continue
        local_path = Path(out_dir) / f"{i}_{name}"
        try:
            req = urllib.request.Request(
                url,
                headers={"Authorization": f"Bearer {token}"},
                method="GET",
            )
            with urllib.request.urlopen(req, timeout=30) as resp:
                local_path.write_bytes(resp.read())
            downloaded[url] = str(local_path)
        except Exception as e:
            print(f"WARN: download failed for {name}: {e}", file=sys.stderr)
    return downloaded


# ---------- Main ----------

def main() -> int:
    ap = argparse.ArgumentParser(description="Read Slack messages via Cursor OAuth tokens")
    sub = ap.add_subparsers(dest="command")

    p_poll = sub.add_parser("poll", help="Poll channels for new messages")
    p_poll.add_argument("--channels", required=True, help="Comma-separated channel IDs")
    p_poll.add_argument("--oldest", default="", help="Only messages after this ts")

    p_thread = sub.add_parser("thread", help="Read a full thread")
    p_thread.add_argument("channel", help="Channel ID")
    p_thread.add_argument("thread_ts", help="Thread timestamp")

    p_dl = sub.add_parser("download-files", help="Download Slack file attachments")
    p_dl.add_argument("file_list", help="Path to JSON file with [{url, name, mimetype}]")
    p_dl.add_argument("out_dir", help="Output directory")

    args = ap.parse_args()
    if not args.command:
        ap.print_help()
        return 1

    try:
        creds = _load_slack_credentials()
    except Exception as e:
        print(f"ERR: Slack token unavailable: {e}", file=sys.stderr)
        return 3

    if args.command == "poll":
        channels = [c.strip() for c in args.channels.split(",") if c.strip()]
        results = cmd_poll(channels, args.oldest, creds)
        print(json.dumps(results, indent=2))
        return 0

    if args.command == "thread":
        result = cmd_thread(args.channel, args.thread_ts, creds)
        print(json.dumps(result, indent=2))
        return 0 if result.get("ok") else 1

    if args.command == "download-files":
        result = cmd_download_files(args.file_list, args.out_dir, creds)
        print(json.dumps(result, indent=2))
        return 0

    return 1


if __name__ == "__main__":
    sys.exit(main())
