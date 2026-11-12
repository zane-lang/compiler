#!/usr/bin/env python3
"""compare.py BEFORE AFTER [THRESHOLD%]: rows of two .tsv files, changes in
cycles / instructions / mispredicts / I1 misses / .text, for rows that move."""
import sys
def rd(p):
    L = open(p).read().splitlines(); h = L[0].split("\t")
    return {(r[0], r[1]): dict(zip(h[2:], r[2:])) for r in map(lambda l: l.split("\t"), L[1:])}
a, b, th = rd(sys.argv[1]), rd(sys.argv[2]), float(next((v for v in sys.argv[3:] if v != '-all'), 0.3))
pc = lambda x, y: 100 * (int(y) / int(x) - 1) if int(x) else 0
print(f"{'program':12}{'build':10}{'cycles':>9}{'instr':>9}{'mispr':>9}{'I1 miss':>9}{'.text':>9}{'text B':>16}")
for k in sorted(a):
    if k not in b: continue
    x, y = a[k], b[k]
    d = [pc(x[c], y[c]) for c in ("cycles", "instructions", "mispredicts", "i1_misses", "text")]
    if "-all" in sys.argv or max(map(abs, d[:3])) >= th or (k[1] == "plain" and max(map(abs, d)) > 0):
        print(f"{k[0]:12}{k[1]:10}" + "".join(f"{v:+8.1f}%" for v in d) + f"{x['text']:>8}>{y['text']}")
