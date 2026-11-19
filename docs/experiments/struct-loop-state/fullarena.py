"""fullarena.py ROUNDS OUT.csv BIN... : the whole LangArena per binary,
interleaved in random order, pinned; appends round,binary,bench,seconds|FAIL."""
import csv, os, random, re, subprocess, sys
rounds, out, bins = int(sys.argv[1]), sys.argv[2], sys.argv[3:]
LINE = re.compile(r"^(\S+): (OK in ([0-9.]+)s|.*)$", re.M)
start = 0
try:
    start = 1 + max(int(r[0]) for r in csv.reader(open(out)))
except (FileNotFoundError, ValueError):
    pass
for r in range(start, start + rounds):
    order = bins[:]; random.shuffle(order)
    for b in order:
        o = subprocess.run(["taskset", "-c", "2", b, "run.js"], capture_output=True, text=True, cwd=os.environ.get("LANGARENA", "/home/user/la-zane")).stdout
        with open(out, "a") as f:
            for name, rest, t in LINE.findall(o):
                if name in ("start", "Summary"): continue
                f.write(f"{r},{b.split('/')[-1]},{name},{t or 'FAIL'}\n")
