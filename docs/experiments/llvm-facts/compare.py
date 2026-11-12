#!/usr/bin/env python3
"""Markdown table of LABEL(s) against BASE: cycles and instructions change
per program and build, and .text change.  compare.py BASE LABEL [LABEL ...]"""
import sys
from pathlib import Path
R = Path(__file__).resolve().parent / "results"
def load(l):
    lines = (R / f"{l}.tsv").read_text().splitlines()[1:]
    return {(c[0], c[1]): c for c in (x.split("\t") for x in lines)}
base, labels = load(sys.argv[1]), sys.argv[2:]
cols = [load(l) for l in labels]
def pct(a, b):
    try: return f"{(int(b) - int(a)) / int(a):+.1%}"
    except Exception: return "?"
print("| program | build | " + " | ".join(f"{l} cyc / instr / text" for l in labels) + " |")
print("| --- | --- |" + " --- |" * len(labels))
for k in sorted(base):
    cells = []
    for c in cols:
        r = c.get(k)
        if not r or r[2] == "ERROR": cells.append("ERROR"); continue
        bad = "" if r[6] == "True" else " **WRONG OUTPUT**"
        cells.append(f"{pct(base[k][2], r[2])} / {pct(base[k][3], r[3])} / {pct(base[k][5], r[5])}{bad}")
    print(f"| {k[0]} | {k[1]} | " + " | ".join(cells) + " |")
