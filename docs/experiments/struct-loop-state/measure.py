"""Interleaved wall-time rounds of LangArena Brainfuck::Array binaries.

measure.py ROUNDS OUT.csv BIN... : one benchmark (, Brainfuck::Array
when unset); each round runs every binary once, in a
fresh random order, pinned to one core, and appends `round,binary,seconds`
(the time the benchmark prints) to OUT.csv as it goes.
"""
import csv, os, random, re, subprocess, sys

rounds, out, bins = int(sys.argv[1]), sys.argv[2], sys.argv[3:]
BENCH = os.environ.get("BENCH", "Brainfuck::Array")
TIME = re.compile(re.escape(BENCH) + r": OK in ([0-9.]+)s")
start = 0
try:
    with open(out) as f:
        start = 1 + max(int(r[0]) for r in csv.reader(f))
except (FileNotFoundError, ValueError):
    pass
for r in range(start, start + rounds):
    order = bins[:]
    random.shuffle(order)
    for b in order:
        o = subprocess.run(["taskset", "-c", "2", b, "run.js", BENCH],
                           capture_output=True, text=True, cwd=os.environ.get("LANGARENA", "/home/user/la-zane")).stdout
        m = TIME.search(o)
        with open(out, "a") as f:
            f.write(f"{r},{b.split('/')[-1]},{m.group(1) if m else 'FAIL'}\n")
