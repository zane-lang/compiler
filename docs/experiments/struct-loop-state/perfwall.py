"""Wall time of each tests/perf program, optimized, for main, fs (#398) and
split.

perfwall.py ROUNDS OUT.csv : calibrates each program's size (its
`arguments`, multiplied while main's build takes under 0.3 s), checks that
the three builds print the same at that size, then runs rounds: each round
runs every (program, compiler) once in random order, pinned to one core,
appending `round,program,compiler,seconds` to OUT.csv.
"""
import csv, json, os, random, subprocess, sys, time

S = os.environ.get("OUT", "out")  # where buildperf.sh put perf/<prog>.<compiler>
PERF = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../../tests/perf")
COMPILERS = os.environ.get("COMPILERS", "main,fs,split").split(",")
rounds, out = int(sys.argv[1]), sys.argv[2]


def run(prog, comp, args, timeout=120):
    t = time.perf_counter()
    r = subprocess.run(["taskset", "-c", "2", f"{S}/perf/{prog}.{comp}", *args], capture_output=True, timeout=timeout)
    return time.perf_counter() - t, r.returncode, r.stdout


sizes_file = f"{S}/perf-sizes.json"
if os.path.exists(sizes_file):
    sizes = json.load(open(sizes_file))
else:
    sizes = {}
    for prog in sorted(os.listdir(PERF)):
        if not os.path.exists(f"{S}/perf/{prog}.{COMPILERS[0]}"):
            continue
        a = open(f"{PERF}/{prog}/arguments").read().split() if os.path.exists(f"{PERF}/{prog}/arguments") else []
        # Doubled while under 0.2 s; a size whose run passes 30 s, or fails,
        # gives back the last one that did not.
        good = a
        while True:
            try:
                t, code, _ = run(prog, COMPILERS[0], a, timeout=30)
            except subprocess.TimeoutExpired:
                a = good
                break
            if code != 0:
                a = good
                break
            good = a
            if t >= 0.2 or len(a) != 1 or not a[0].isdigit():
                break
            a = [str(int(a[0]) * 2)]
        outs = {c: run(prog, c, a)[1:] for c in COMPILERS}
        if len({(code, o) for code, o in outs.values()}) != 1:
            print(f"MISMATCH {prog} at {a}: {[(c, code) for c, (code, _) in outs.items()]}", flush=True)
            continue
        sizes[prog] = a
        print(f"{prog}: {a}", flush=True)
    json.dump(sizes, open(sizes_file, "w"))

start = 0
try:
    start = 1 + max(int(r[0]) for r in csv.reader(open(out)))
except (FileNotFoundError, ValueError):
    pass
jobs = [(p, c) for p in sizes for c in COMPILERS]
for r in range(start, start + rounds):
    random.shuffle(jobs)
    for p, c in jobs:
        t, code, _ = run(p, c, sizes[p])
        with open(out, "a") as f:
            f.write(f"{r},{p},{c},{t if code == 0 else 'FAIL'}\n")
