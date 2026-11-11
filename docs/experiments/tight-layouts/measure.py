#!/usr/bin/env python3
"""Builds bench/layouts once per mode with --optimize, checks that every
mode prints the same checksum, and reports each shape's median wall time
and peak resident memory over RUNS runs, the modes' runs interleaved.

    pixi run -- python3 docs/experiments/tight-layouts/measure.py [N] [PASSES] [RUNS]

Run from the repository root after `pixi run just build`."""
import os, statistics, subprocess, sys, time

here = os.path.dirname(os.path.abspath(__file__))
zanec = os.path.abspath("_build/default/bin/zanec/zanec.exe")
work = os.environ.get("WORK", "/tmp/zane-tight-measure")
n = sys.argv[1] if len(sys.argv) > 1 else "10000000"
passes = sys.argv[2] if len(sys.argv) > 2 else "10"
runs = int(sys.argv[3]) if len(sys.argv) > 3 else 5
modes = [("default", None), ("structs", "structs"), ("all", "all")]
shapes = {1: "Pair", 2: "Flagged", 3: "Trio", 4: "Outer", 5: "Maybe", 6: "Wide", 7: "Trio scattered", 8: "Wide scattered"}

os.makedirs(work, exist_ok=True)
exes = {}
for name, pack in modes:
    env = dict(os.environ)
    env.pop("ZANE_PACK", None)
    if pack:
        env["ZANE_PACK"] = pack
    exe = os.path.join(work, f"layouts.{name}")
    subprocess.run([zanec, "--build", exe, "--optimize", "--package", os.path.join(here, "bench/layouts")], env=env, check=True)
    exes[name] = exe

def run(exe, shape):
    start = time.perf_counter()
    p = subprocess.Popen([exe, str(shape), n, passes], stdout=subprocess.PIPE)
    out = p.stdout.read()
    _, status, usage = os.wait4(p.pid, 0)
    wall = time.perf_counter() - start
    if status != 0:
        sys.exit(f"{exe} {shape}: exit status {status}")
    return out.strip().decode(), wall, usage.ru_maxrss / 1024

print(f"N={n} PASSES={passes} RUNS={runs}")
print("| shape | " + " | ".join(f"{m} time | {m} peak" for m, _ in modes) + " |")
print("| --- |" + " --- | --- |" * len(modes))
for shape, label in shapes.items():
    walls = {m: [] for m, _ in modes}
    peaks = {m: [] for m, _ in modes}
    sums = set()
    for _ in range(runs):
        for m, _ in modes:
            out, wall, peak = run(exes[m], shape)
            sums.add(out)
            walls[m].append(wall)
            peaks[m].append(peak)
    if len(sums) != 1:
        sys.exit(f"shape {shape}: the modes disagree: {sums}")
    cells = [f"{statistics.median(walls[m]):.3f} s | {statistics.median(peaks[m]):.0f} MiB" for m, _ in modes]
    print(f"| {shape} {label} | " + " | ".join(cells) + " |", flush=True)
