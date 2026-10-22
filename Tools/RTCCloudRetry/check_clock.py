#!/usr/bin/env python3
"""Check saved real-app remote clock summaries; does not launch synthetic clocks."""
import argparse
import json
import re
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('log', type=Path)
parser.add_argument('--minimum-calls', type=int, default=2)
args = parser.parse_args()
pattern = re.compile(r'remote audio clock: frames=(\d+) elapsed_ms=([\d.]+) work_ms=([\d.]+) sleep_ms=([\d.]+) max_work_ms=([\d.]+) max_sleep_ms=([\d.]+)')
records = []
for match in pattern.finditer(args.log.read_text()):
    frames, elapsed, work, sleep, max_work, max_sleep = map(float, match.groups())
    rate = frames * 1000 / elapsed if elapsed else 0
    # Includes short peer setup/teardown; require sustained real-time delivery.
    passed = elapsed >= 3000 and 90 <= rate <= 101 and max_sleep < 50
    records.append(dict(frames=int(frames), elapsed_ms=elapsed, frames_per_second=rate,
                        max_sleep_ms=max_sleep, passed=passed))
passed = len(records) >= args.minimum_calls and all(r['passed'] for r in records)
print(json.dumps(dict(calls=records, passed=passed), indent=2))
raise SystemExit(0 if passed else 1)
