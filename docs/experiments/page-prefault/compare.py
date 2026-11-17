#!/usr/bin/env python3
"""Each ZANE_PREFAULT setting against the others on the size-scaled programs
(README, step 1), runs interleaved so drift in a shared machine hits every
setting alike. Prints per program and setting the median and best wall time
and CPU time (user+sys) over N rounds, and the minor faults (the kernel
counts pages MADV_POPULATE_WRITE fills as minor faults too, so fewer traps
do not show there). Builds with measure.py first; usage:
compare.py [N [PROGRAM,... [MODE,...]]]"""
import os, statistics, subprocess, sys, time
from pathlib import Path

E = Path(__file__).resolve().parent
PERF, WORK = E.parents[2] / "tests" / "perf", E.parents[2] / "_build" / "page-prefault"
SIZES = {"growth": 20, "tokens": 20, "bits": 20, "nodes": 20, "stress": 10, "paths": 5,
         "copies": 1.15, "returns": 1.25, "handover": 20, "spans": 20}
MODES = ["off", "chunks", "spans", "all"]


def run(exe, args, mode):
    t = time.perf_counter()
    p = subprocess.Popen([exe, *args], stdout=subprocess.DEVNULL, env=dict(os.environ, ZANE_PREFAULT=mode))
    _, status, ru = os.wait4(p.pid, 0)
    assert status == 0, (exe, status)
    return time.perf_counter() - t, ru.ru_utime + ru.ru_stime, ru.ru_minflt, ru.ru_maxrss


n = int(sys.argv[1]) if len(sys.argv) > 1 else 15
if len(sys.argv) > 2:
    SIZES = {k: SIZES[k] for k in sys.argv[2].split(",")}
if len(sys.argv) > 3:
    MODES = sys.argv[3].split(",")
subprocess.run([sys.executable, E / "measure.py", "--runs", "1", *SIZES], check=True, stdout=subprocess.DEVNULL)
print("program\tmode\twall_med\twall_best\tcpu_med\tcpu_best\tfaults\tmaxrss_kb")
for name, scale in SIZES.items():
    args = [str(max(1, int(int(x) * scale))) for x in (PERF / name / "arguments").read_text().split()]
    rs = {m: [] for m in MODES}
    for _ in range(n):
        for m in MODES:
            rs[m].append(run(WORK / name, args, m))
    for m in MODES:
        w, c = [r[0] for r in rs[m]], [r[1] for r in rs[m]]
        print(f"{name}\t{m}\t{statistics.median(w):.4f}\t{min(w):.4f}\t{statistics.median(c):.4f}\t{min(c):.4f}"
              f"\t{rs[m][0][2]}\t{rs[m][0][3]}", flush=True)
