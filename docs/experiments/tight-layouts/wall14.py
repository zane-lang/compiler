#!/usr/bin/env python3
"""Step 14's wall-clock check: one perf program built by two compilers, each
optimized and tiered, timed by wall clock with the runs interleaved. Prints
each build's best and median against the first compiler's.

    python3 docs/experiments/tight-layouts/wall14.py BEFORE AFTER [PROGRAM] [SCALE] [RUNS]

BEFORE and AFTER are zanec executables, for example `main`'s and this
branch's `_build/default/bin/zanec/zanec.exe` copied aside. PROGRAM is a
directory of tests/perf (default `entities`), its first argument multiplied
by SCALE (default 10), and each build is run RUNS times (default 15). A
tiered build runs as tests/perf runs it, with tier 1 loaded before `main`.
Run from the repository root.
"""
import atexit, os, shutil, subprocess, sys, tempfile, time

before, after = sys.argv[1], sys.argv[2]
name = sys.argv[3] if len(sys.argv) > 3 else "entities"
scale = int(sys.argv[4]) if len(sys.argv) > 4 else 10
runs = int(sys.argv[5]) if len(sys.argv) > 5 else 15
args = open(f"tests/perf/{name}/arguments").read().split()
if args:
    args[0] = str(int(args[0]) * scale)
work = tempfile.mkdtemp()
atexit.register(shutil.rmtree, work, ignore_errors=True)
package = ["--package", f"tests/perf/{name}"]
builds = {}
for label, zanec in (("before", before), ("after", after)):
    exe, lib = os.path.join(work, f"{label}-opt"), os.path.join(work, f"{label}-t1")
    subprocess.run([zanec, "--build", exe, "--optimize", *package], check=True)
    subprocess.run([zanec, "--build", exe + "-t0", "--tiered", *package], check=True)
    subprocess.run([zanec, "--tier-up", lib, *package], check=True)
    builds[label, "optimized"] = ([exe, *args], os.environ)
    builds[label, "tiered"] = ([exe + "-t0", *args], {**os.environ, "ZANE_TIER_UP": lib, "ZANE_TIER_WAIT": "1"})
times = {k: [] for k in builds}
outputs = {}
for _ in range(runs):
    for k, (command, env) in builds.items():
        start = time.perf_counter()
        ran = subprocess.run(command, env=env, capture_output=True, check=True)
        times[k].append(time.perf_counter() - start)
        outputs.setdefault(k[1], set()).add(ran.stdout)
for build in ("optimized", "tiered"):
    if len(outputs[build]) != 1:
        sys.exit(f"{name} {build}: the two compilers' builds printed different output")
    b, a = sorted(times["before", build]), sorted(times["after", build])
    best, median = (a[0] - b[0]) / b[0], (a[runs // 2] - b[runs // 2]) / b[runs // 2]
    print(f"{name} {build:9} before {b[0] * 1000:8.1f} ms best, {b[runs // 2] * 1000:8.1f} median;"
          f" after {a[0] * 1000:8.1f}, {a[runs // 2] * 1000:8.1f}; best {best:+.1%}, median {median:+.1%}")
