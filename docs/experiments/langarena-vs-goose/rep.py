#!/usr/bin/env python3
# rep.py TRI.json [ZANE_KEY] : Markdown table of min times and Zane / Goose ratios
# from a tri.py result, worst ratio against Goose/clang first.
import sys, json, math
t = json.load(open(sys.argv[1])); z = sys.argv[2] if len(sys.argv) > 2 else 'zane'
rows = []
for n, v in t[z].items():
    if None in v or None in t['clang'].get(n, [None]) or None in t['gcc'].get(n, [None]):
        print(f'{n}: ERR'); continue
    zv, cv, gv = min(v), min(t['clang'][n]), min(t['gcc'][n])
    rows.append((zv / cv, zv / gv, n, zv, cv, gv))
rows.sort(reverse=True)
print('| Test | Zane (s) | Goose-clang (s) | Goose-gcc (s) | Zane / clang | Zane / gcc |')
print('| --- | ---: | ---: | ---: | ---: | ---: |')
for rc, rg, n, zv, cv, gv in rows:
    print(f'| {n} | {zv:.3f} | {cv:.3f} | {gv:.3f} | {rc:.2f} | {rg:.2f} |')
if not rows: sys.exit('no comparable tests')
g = lambda i: math.exp(sum(math.log(r[i]) for r in rows) / len(rows))
print(f'\ngeomean Zane / clang {g(0):.3f} (faster on {sum(r[0] < 1 for r in rows)}), '
      f'Zane / gcc {g(1):.3f} (faster on {sum(r[1] < 1 for r in rows)}), {len(rows)} tests')
