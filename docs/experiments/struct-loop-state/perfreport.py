"""Per program, fs (#398) and split against main: the median over rounds of
the paired ratio, with its 25th-75th percentile; then the geometric mean
over programs, and the programs where a ratio's whole spread is past 2%."""
import csv, math, statistics, sys
from collections import defaultdict

t = defaultdict(dict)
for r, p, c, s in csv.reader(open(sys.argv[1])):
    if s != "FAIL":
        t[(p, c)][int(r)] = float(s)


def q(xs, f):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(f * (len(xs) - 1) + 0.5))]


progs = sorted({p for p, _ in t})
logs = defaultdict(list)
clear = defaultdict(list)
print(f"{'program':12s} {'main med':>9s}  {'fs/main':>22s}  {'split/main':>22s}")
for p in progs:
    base = t.get((p, "main"), {})
    cells = []
    for c in ["fs", "split"]:
        rs = [t[(p, c)][r] / base[r] for r in t.get((p, c), {}) if r in base]
        if not rs:
            cells.append(" " * 22)
            continue
        m, lo, hi = statistics.median(rs), q(rs, 0.25), q(rs, 0.75)
        logs[c].append(math.log(m))
        if lo > 1.02 or hi < 0.98:
            clear[c].append(f"{p} {m:.3f}")
        cells.append(f"{m:.3f} [{lo:.3f},{hi:.3f}]")
    print(f"{p:12s} {statistics.median(base.values()):9.3f}  {cells[0]:>22s}  {cells[1]:>22s}")
print()
for c in ["fs", "split"]:
    print(f"{c}: geometric mean vs main {math.exp(statistics.mean(logs[c])):.4f} over {len(logs[c])} programs")
    print(f"  outside ±2% (whole p25-p75 spread): {', '.join(clear[c]) or 'none'}")
