#!/usr/bin/env python3
"""langbench's Zane programs against core under Callgrind, in estimated
cycles as tests/perf/run counts them (same caches and weights), at each
test's check size. Linux only; run inside the pixi environment:

    pixi run -- python3 docs/experiments/tight-layouts/langbench_cycles.py LANGBENCH CORE
"""
import importlib.util, os, re, subprocess, sys, tempfile

bench, core = (os.path.abspath(a) for a in sys.argv[1:3])
spec = importlib.util.spec_from_file_location("tests", os.path.join(bench, "tests.py"))
tests = importlib.util.module_from_spec(spec); spec.loader.exec_module(tests)
ZANEC = os.path.abspath("_build/default/bin/zanec/zanec.exe")
MODES = [("default", {}), ("default+unswitch", {"ZANE_UNSWITCH": "1"}), ("niche", {"ZANE_PACK": "niche"})]
work = tempfile.mkdtemp()

def cycles(exe, args):
    out = f"{exe}.cg"
    subprocess.run(["valgrind", "--tool=callgrind", "--cache-sim=yes", "--branch-sim=yes",
                    "--I1=32768,8,64", "--D1=32768,8,64", "--LL=8388608,16,64",
                    f"--callgrind-out-file={out}", exe, *args], capture_output=True, check=True)
    events = summary = None
    for line in open(out):
        if line.startswith("events:"): events = line.split()[1:]
        if line.startswith("summary:") or line.startswith("totals:"): summary = list(map(int, line.split()[1:]))
    c = dict(zip(events, summary))
    l1 = c["I1mr"] + c["D1mr"] + c["D1mw"]
    ll = c["ILmr"] + c["DLmr"] + c["DLmw"]
    return c["Ir"] + 10 * l1 + 100 * ll + 20 * (c["Bcm"] + c["Bim"])

print(f"{'test':14}" + "".join(f"{m:>28}" for m, _ in MODES), flush=True)
for t in tests.TESTS:
    tid = t["id"]
    if not os.path.isdir(os.path.join(bench, "bin", tid)): continue
    cells, base = [], None
    for name, extra in MODES:
        env = {k: v for k, v in os.environ.items() if k not in ("ZANE_PACK", "ZANE_UNSWITCH")}
        env.update(extra)
        exe = os.path.join(work, f"{tid}-{name.replace('+', '-')}")
        b = subprocess.run([ZANEC, "--build", exe, "--optimize", "--package", f"{tid}={bench}/bin/{tid}",
                            "--package", f"bench={bench}/lib/bench", "--package", f"core={core}/lib/core",
                            "--package", f"math={core}/lib/math"], env=env, capture_output=True)
        if b.returncode != 0: cells.append("refused"); continue
        if subprocess.run([exe, *t["check_args"]], capture_output=True, text=True).stdout != t["check_expected"]:
            cells.append("WRONG"); continue
        c = cycles(exe, t["check_args"])
        if base is None: base = c
        cells.append(f"{c:>14,} {100*(c/base-1):+6.2f}%")
    print(f"{tid:14}" + "".join(f"{c:>28}" for c in cells), flush=True)
