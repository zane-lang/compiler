#!/usr/bin/env python3
"""Builds bench/layouts once per mode with --optimize, checks that every
mode prints the same checksum, and reports each shape's median wall time
and peak resident memory over RUNS runs, the modes' runs interleaved.

    pixi run -- python3 docs/experiments/tight-layouts/measure.py [N] [PASSES] [RUNS] [MODE...]

A mode is `default`, or switches joined by commas, e.g.
`ZANE_PACK=structs,ZANE_PACK_HINTS=0`; the default modes are `default`,
`ZANE_PACK=structs` and `ZANE_PACK=all`.

Run from the repository root after `pixi run just build`."""
import os, statistics, subprocess, sys, time

windows = sys.platform == "win32"
suffix = ".exe" if windows else ""


def peak_mib(p):
    """The finished process's peak memory in MiB: its peak working set on
    Windows, which has no wait4, and its maximum resident set elsewhere."""
    import ctypes
    from ctypes import wintypes

    class Counters(ctypes.Structure):
        _fields_ = [("cb", wintypes.DWORD), ("PageFaultCount", wintypes.DWORD)] + [
            (f, ctypes.c_size_t) for f in ("PeakWorkingSetSize", "WorkingSetSize", "QuotaPeakPagedPoolUsage", "QuotaPagedPoolUsage", "QuotaPeakNonPagedPoolUsage", "QuotaNonPagedPoolUsage", "PagefileUsage", "PeakPagefileUsage")
        ]

    c = Counters()
    c.cb = ctypes.sizeof(c)
    ctypes.WinDLL("psapi").GetProcessMemoryInfo(wintypes.HANDLE(int(p._handle)), ctypes.byref(c), c.cb)
    return c.PeakWorkingSetSize / (1024 * 1024)

here = os.path.dirname(os.path.abspath(__file__))
zanec = os.path.abspath("_build/default/bin/zanec/zanec.exe")
import tempfile
work = os.environ.get("WORK", os.path.join(tempfile.gettempdir(), "zane-tight-measure"))
n = sys.argv[1] if len(sys.argv) > 1 else "10000000"
passes = sys.argv[2] if len(sys.argv) > 2 else "10"
runs = int(sys.argv[3]) if len(sys.argv) > 3 else 5
names = sys.argv[4:] or ["default", "ZANE_PACK=structs", "ZANE_PACK=all"]
modes = [(m, [] if m == "default" else m.split(",")) for m in names]
shapes = {1: "Pair", 2: "Flagged", 3: "Trio", 4: "Outer", 5: "Maybe", 6: "Wide", 7: "Trio scattered", 8: "Wide scattered", 9: "Chosen", 10: "Nested", 11: "Quads", 12: "Trio plain loop"}
if os.environ.get("SHAPES"):
    shapes = {int(k): shapes[int(k)] for k in os.environ["SHAPES"].split(",")}

os.makedirs(work, exist_ok=True)
exes = {}
for i, (name, switches) in enumerate(modes):
    env = {k: v for k, v in os.environ.items() if not k.startswith("ZANE_PACK")}
    env.update(s.split("=", 1) for s in switches)
    exe = os.path.join(work, f"layouts{i}{suffix}")
    subprocess.run([zanec, "--build", exe, "--optimize", "--package", os.path.join(here, "bench/layouts")], env=env, check=True)
    exes[name] = exe

def run(exe, shape):
    start = time.perf_counter()
    p = subprocess.Popen([exe, str(shape), n, passes], stdout=subprocess.PIPE)
    out = p.stdout.read()
    if windows:
        status = p.wait()
        wall = time.perf_counter() - start
        peak = peak_mib(p)
    else:
        _, status, usage = os.wait4(p.pid, 0)
        wall = time.perf_counter() - start
        # Linux gives the peak in KiB, macOS in bytes.
        peak = usage.ru_maxrss / (1024 * 1024 if sys.platform == "darwin" else 1024)
    if status != 0:
        sys.exit(f"{exe} {shape}: exit status {status}")
    return out.strip().decode(), wall, peak

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
