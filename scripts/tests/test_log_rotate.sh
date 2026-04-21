#!/bin/bash
# Offline test for scripts/lib/log-rotate.sh.
# Creates dummy log files, runs rotate_if_large, verifies that:
#   - files above threshold end up in logs/archive/
#   - files below threshold stay put
#   - archive pruning keeps only LOG_ARCHIVE_KEEP files

set -euo pipefail

# Always resolve SKILL_DIR from the test's own location — env leakage from
# other tests/cleanroom fixtures must not redirect us to an unrelated tree.
SKILL_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

LOG_DIR="$TMP/logs"
mkdir -p "$LOG_DIR"

# tiny threshold so we don't need to create MBs of data
export LOG_ROTATE_THRESHOLD_BYTES=1024
export LOG_ARCHIVE_KEEP=3

# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/log-rotate.sh"

# ---- case 1: small file → no rotate -----------------------------------------
small="$LOG_DIR/small.log"
printf 'hello\n' > "$small"
rotate_if_large "$small"
[[ -f "$small" ]] || { echo "FAIL: small.log vanished"; exit 1; }
[[ ! -d "$LOG_DIR/archive" ]] || {
  count=$(ls "$LOG_DIR/archive" 2>/dev/null | wc -l | tr -d ' ')
  (( count == 0 )) || { echo "FAIL: archive populated for small file"; exit 1; }
}
echo "PASS small.log not rotated"

# ---- case 2: big file → rotated --------------------------------------------
big="$LOG_DIR/big.log"
dd if=/dev/zero of="$big" bs=1 count=2048 >/dev/null 2>&1
rotate_if_large "$big"
# Wait briefly for background gzip
sleep 0.5
# Fresh file exists and is tiny
[[ -f "$big" ]] || { echo "FAIL: big.log not re-created"; exit 1; }
sz=$(stat -f "%z" "$big" 2>/dev/null || stat -c "%s" "$big" 2>/dev/null)
(( sz < 1024 )) || { echo "FAIL: big.log still large: $sz"; exit 1; }
# Archive contains an entry (gzipped or raw)
ls "$LOG_DIR/archive/big-"*.log* >/dev/null 2>&1 \
  || { echo "FAIL: no archive for big.log"; ls -la "$LOG_DIR/archive" || true; exit 1; }
echo "PASS big.log rotated"

# ---- case 3: archive pruning -----------------------------------------------
# Create more than LOG_ARCHIVE_KEEP archives for the same base, then rotate
# once more to trigger prune.
for i in 1 2 3 4 5; do
  touch -t "20240101010$i" "$LOG_DIR/archive/multi-2024010101010$i.log.gz"
done
dd if=/dev/zero of="$LOG_DIR/multi.log" bs=1 count=2048 >/dev/null 2>&1
rotate_if_large "$LOG_DIR/multi.log"
sleep 0.5
remaining=$(ls "$LOG_DIR/archive/multi-"*.log.gz 2>/dev/null | wc -l | tr -d ' ')
(( remaining <= LOG_ARCHIVE_KEEP )) \
  || { echo "FAIL: pruning did not trim: $remaining survivors"; ls "$LOG_DIR/archive" || true; exit 1; }
echo "PASS archive pruning keeps ≤ $LOG_ARCHIVE_KEEP"

# ---- case 4: rotate_all walks the dir --------------------------------------
dd if=/dev/zero of="$LOG_DIR/another.log" bs=1 count=2048 >/dev/null 2>&1
dd if=/dev/zero of="$LOG_DIR/yet.log"     bs=1 count=2048 >/dev/null 2>&1
rotate_all "$LOG_DIR"
sleep 0.5
for f in another yet; do
  ls "$LOG_DIR/archive/${f}-"*.log* >/dev/null 2>&1 \
    || { echo "FAIL: rotate_all didn't touch $f"; exit 1; }
done
echo "PASS rotate_all processes every log"

echo "OK test_log_rotate"
