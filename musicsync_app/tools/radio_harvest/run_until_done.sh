#!/usr/bin/env bash
# Runs harvest.py until it finishes. The built-in watchdog makes a stuck run exit(1);
# everything fetched/verified so far is cached, so each retry resumes almost where it stopped.
cd "$(dirname "$0")/../.." || exit 1
for attempt in 1 2 3 4 5 6 7 8; do
  echo "=== attempt $attempt $(date +%H:%M:%S) ==="
  python -X utf8 tools/radio_harvest/harvest.py "$@" && exit 0
  echo "=== attempt $attempt exited with $? ==="
  sleep 3
done
echo "=== GAVE UP after 8 attempts ==="
exit 1
