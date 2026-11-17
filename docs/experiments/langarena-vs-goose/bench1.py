#!/usr/bin/env python3
"""Interleave several binaries on one run.js test, pinned to one CPU, and
print each one's min, median and max reported time, and its median over the
first binary's.

usage: bench1.py ROUNDS TEST BIN...   (e.g. bench1.py 15 Json::ParseMapping c/target/prod/benchmark zane-a zane-b)

A test whose checksum fails (a variant that skips work on purpose) still
reports its time.
"""
import re, statistics, subprocess, sys
import os
from pathlib import Path

ROOT = Path(os.environ.get('LANGARENA') or sys.exit('set LANGARENA to a LangArena checkout')).resolve()
rounds, test, bins = int(sys.argv[1]), sys.argv[2], sys.argv[3:]
times = {b: [] for b in bins}
for r in range(rounds):
    # The order rotates each round.
    for b in bins[r % len(bins):] + bins[:r % len(bins)]:
        out = subprocess.run(['taskset', '-c', '2', b, str(ROOT / 'run.js'), test],
                             text=True, capture_output=True).stdout
        m = re.search(re.escape(test) + r': (.*?) in ([0-9.]+)s', out)
        if not m:
            sys.exit(f'{b}: no time in output:\n{out[-300:]}')
        times[b].append(float(m.group(2)))
first = statistics.median(times[bins[0]])
for b in bins:
    v = times[b]
    med = statistics.median(v)
    print(f'{b[-40:]:>40}  min {min(v):.3f}  med {med:.3f}  max {max(v):.3f}  med/first {med / first:.3f}')
