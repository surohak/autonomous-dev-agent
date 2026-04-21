#!/bin/bash
# test_tsv.sh — regression guard for the `IFS=$'\t' read` tab-collapse bug
# that once made non-running tickets appear as RUNNING in /tickets.
set -euo pipefail

# Simulate the old (buggy) shape: empty badge and pid between summary and size.
# In bash, IFS=$'\t' treats tab as whitespace-IFS and collapses runs of it,
# so empty fields get eaten, shifting the size flag into TBADGE.
out=$(printf 'UA-1\tTo Do\tMedium\tsummary\t\t\t1\n' | while IFS=$'\t' read -r K S P SUM B PID SZ; do
  printf 'B=[%s] PID=[%s] SZ=[%s]\n' "$B" "$PID" "$SZ"
done)
# Expected-bad: B=[1] (the tabs collapsed)
if [[ "$out" == *"B=[1]"* ]]; then
  echo "reproduced bug: tabs collapsed into B"
else
  echo "HUH — expected tab collapse in simulation: $out"
  exit 1
fi

# Sentinel form should round-trip correctly.
out2=$(printf 'UA-1\tTo Do\tMedium\tsummary\t-\t-\t1\n' | while IFS=$'\t' read -r K S P SUM B PID SZ; do
  [[ "$B"   == "-" ]] && B=""
  [[ "$PID" == "-" ]] && PID=""
  printf 'B=[%s] PID=[%s] SZ=[%s]\n' "$B" "$PID" "$SZ"
done)
if [[ "$out2" != "B=[] PID=[] SZ=[1]" ]]; then
  echo "sentinel fix did not round-trip: $out2"
  exit 1
fi
echo "tsv round-trip OK with sentinel fix"
