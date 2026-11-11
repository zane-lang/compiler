#!/usr/bin/env python3
"""tests/perf programs built with --optimize in each mode, checked against
their golden output and timed by wall clock, for machines where the perf
gate's Callgrind cannot run. Each mode's runs are interleaved; the best of
RUNS is reported against the default build.

    python3 docs/experiments/tight-layouts/programs.py [RUNS] [PROGRAM...]

Run from the repository root after `just build`. With no program named,
every one is run. SCALE=K in the environment multiplies each program's
first argument by K, so a run lasts long enough to time; the modes are
then checked against one another, since the golden is for the unscaled
size. A program named as NAME*K is scaled by K alone.
"""
import os, subprocess, sys, tempfile, time

runs = int(sys.argv[1]) if len(sys.argv) > 1 else 5
names = sys.argv[2:] or sorted(d for d in os.listdir("tests/perf") if os.path.isfile(f"tests/perf/{d}/main.zn"))
suffix = ".exe" if sys.platform == "win32" else ""
zanec = os.path.abspath("_build/default/bin/zanec/zanec.exe")
MODES = [("default", {}), ("default+unswitch", {"ZANE_UNSWITCH": "1"}), ("niche", {"ZANE_PACK": "niche"})]
work = tempfile.mkdtemp()
print(f"{'program':12}" + "".join(f"{m:>26}" for m, _ in MODES), flush=True)
for p in names:
    p, _, k = p.partition("*")
    args = open(f"tests/perf/{p}/arguments").read().split()
    scale = int(k or os.environ.get("SCALE", "1"))
    if scale != 1 and args: args[0] = str(int(args[0]) * scale)
    want = open(f"tests/perf/golden/{p}.out", "rb").read().replace(b"\r\n", b"\n")
    exes = {}
    for m, extra in MODES:
        env = {k: v for k, v in os.environ.items() if k not in ("ZANE_PACK", "ZANE_UNSWITCH")}
        env.update(extra)
        exes[m] = os.path.join(work, f"{p}-{m.replace('+', '-')}{suffix}")
        subprocess.run([zanec, "--build", exes[m], "--optimize", "--package", f"tests/perf/{p}"], env=env, check=True)
    best, wrong, outs = {m: 1e9 for m, _ in MODES}, set(), {}
    for _ in range(runs):
        for m, _ in MODES:
            s = time.perf_counter()
            out = subprocess.run([exes[m], *args], capture_output=True, timeout=600).stdout
            best[m] = min(best[m], time.perf_counter() - s)
            out = out.replace(b"\r\n", b"\n")
            if scale == 1 and out != want: wrong.add(m)
            want = want if scale == 1 else outs.setdefault("first", out)
            if scale != 1 and out != want: wrong.add(m)
    base = best["default"]
    print(f"{p:12}" + "".join(f"{f'{best[m]:8.3f}s {100*(best[m]/base-1):+6.1f}%' + (' WRONG' if m in wrong else ''):>26}" for m, _ in MODES), flush=True)
