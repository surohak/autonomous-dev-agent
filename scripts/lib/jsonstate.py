"""
scripts/lib/jsonstate.py — atomic JSON state helpers shared by every script
that mutates files under cache/.

Key guarantees:
  * Exclusive flock on <path>.lock (portable to macOS) while the body runs.
  * Atomic write via tempfile + os.replace — readers never see a partial file.
  * Defensive read — corrupted or missing files produce `default` instead of
    raising, so a one-time failure in one writer never poisons the state.

Usage
-----
    from jsonstate import locked_json, read_json

    # read-modify-write
    with locked_json("/path/to/foo.json", {}) as ref:
        ref[0]["hello"] = "world"

    # read-only (no lock, tolerant of missing/corrupt file)
    data = read_json("/path/to/foo.json", {})

PYTHONPATH must include scripts/lib/ — env.sh handles that.
"""

from __future__ import annotations

import contextlib
import fcntl
import json
import os
import tempfile
import time
from typing import Any, Iterator, List


@contextlib.contextmanager
def locked_json(path: str, default: Any = None) -> Iterator[List[Any]]:
    """Read, yield a one-element list holding the value, then atomically write
    back whatever the caller placed in `ref[0]`.

    We yield a list (not the dict) so the caller can *replace* the whole value
    by assigning to `ref[0]`, not just mutate in place.
    """
    if default is None:
        default = {}
    parent = os.path.dirname(path) or "."
    os.makedirs(parent, exist_ok=True)

    lock_path = path + ".lock"
    lf = open(lock_path, "w")
    try:
        # Exclusive flock with bounded retries (~2.5s)
        for _ in range(50):
            try:
                fcntl.flock(lf, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                time.sleep(0.05)
        else:
            raise TimeoutError(f"could not lock {lock_path}")

        # Load (tolerant of missing / corrupt)
        try:
            with open(path) as f:
                data = json.load(f)
            if not isinstance(data, type(default)):
                data = default
        except Exception:
            data = default

        ref: List[Any] = [data]
        yield ref

        # Atomic write: tempfile in same dir → os.replace
        tmp = tempfile.NamedTemporaryFile(
            mode="w", dir=parent,
            prefix=f".{os.path.basename(path)}.", suffix=".tmp",
            delete=False,
        )
        try:
            json.dump(ref[0], tmp, indent=2)
            tmp.flush()
            os.fsync(tmp.fileno())
            tmp.close()
            os.replace(tmp.name, path)
        except Exception:
            try:
                os.unlink(tmp.name)
            except Exception:
                pass
            raise
    finally:
        try:
            fcntl.flock(lf, fcntl.LOCK_UN)
        except Exception:
            pass
        lf.close()


def read_json(path: str, default: Any = None) -> Any:
    """Best-effort read. Returns `default` on missing/corrupt file."""
    if default is None:
        default = {}
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception:
        return default
    return data


def write_json(path: str, value: Any) -> None:
    """Atomic write without the read-modify-write lock dance. Use locked_json
    when you need read-modify-write."""
    parent = os.path.dirname(path) or "."
    os.makedirs(parent, exist_ok=True)
    tmp = tempfile.NamedTemporaryFile(
        mode="w", dir=parent,
        prefix=f".{os.path.basename(path)}.", suffix=".tmp",
        delete=False,
    )
    try:
        json.dump(value, tmp, indent=2)
        tmp.flush()
        os.fsync(tmp.fileno())
        tmp.close()
        os.replace(tmp.name, path)
    except Exception:
        try:
            os.unlink(tmp.name)
        except Exception:
            pass
        raise
