#!/usr/bin/env python3
"""Round 7: whole runs of one program at one size, each after the machine
has sat idle for GAP seconds, with huge pages and with ZANE_HUGE=0 in
turn; appends to ../results/cold.tsv. Columns as whole.py's, with the gap
after the size.

  cold.py PROGRAM LOG2BYTES GAP RUNS   (from the repository root, in pixi)
"""
import importlib.util, os, sys, time
spec = importlib.util.spec_from_file_location("whole", "docs/experiments/prefetch-reorder/programs/whole.py")
w = importlib.util.module_from_spec(spec); spec.loader.exec_module(w)
program, size, gap, reps = sys.argv[1], sys.argv[2], float(sys.argv[3]), int(sys.argv[4])
exe = f"/tmp/claude-0/b/{program}_w"
w.build(program, exe)
off = {**os.environ, "ZANE_HUGE": "0"}
out = open("docs/experiments/prefetch-reorder/results/cold.tsv", "a")
for rep in range(reps):
    for mode in (("on", "off") if rep % 2 == 0 else ("off", "on")):
        time.sleep(gap)
        t, st, flt, d, _ = w.run(exe, [size, "1", str(w.OPS[program])], off if mode == "off" else None)
        row = [program, size, f"{gap:g}", mode, str(rep), *(f"{x:.4f}" for x in t), f"{st:.3f}", str(flt), *map(str, d)]
        out.write("\t".join(row) + "\n"); out.flush(); print(*row, flush=True)
