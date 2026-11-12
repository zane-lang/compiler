#!/usr/bin/env python3
"""langbench.py ZANEC LABEL LANGBENCH CORE: build each langbench program with
--optimize (as `zane build` does) and, tiered, run it under Callgrind at
1/SCALE of langbench's size; write LABEL.tsv: program, build, cycles,
instructions, mispredicts, I1 misses, .text."""
import importlib.machinery, importlib.util, os, shutil, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_loader("perfrun", importlib.machinery.SourceFileLoader("perfrun", str(ROOT / "tests/perf/run")))
run = importlib.util.module_from_spec(spec); spec.loader.exec_module(run)
zanec, label, bench, core = sys.argv[1], sys.argv[2], *map(os.path.abspath, sys.argv[3:5])
sys.path.insert(0, bench)
ts = importlib.util.spec_from_file_location("tests", f"{bench}/tests.py"); tests = importlib.util.module_from_spec(ts); ts.loader.exec_module(tests)
SCALE = 50
def text(p):
    out = subprocess.run(["size", "-A", str(p)], capture_output=True, text=True).stdout
    return sum(int(l.split()[1]) for l in out.splitlines() if l.startswith(".text"))
pk = lambda t: ["--package", f"{t}={bench}/bin/{t}", "--package", f"bench={bench}/lib/bench",
                "--package", f"core={core}/lib/core", "--package", f"math={core}/lib/math"]
def one(t, work, build):
    tid = t["id"]; args = [str(int(a) // SCALE) if a.isdigit() and int(a) >= 1000 else a for a in t["args"]]
    exe, prof = work / f"{tid}.{build}", work / f"{tid}.{build}.cg"
    flags = ["--optimize"] if build == "optimized" else ["--tiered"]
    b = subprocess.run([zanec, "--build", exe, *flags, *pk(tid)], capture_output=True, text=True)
    if b.returncode: return tid, build, f"build failed {b.stderr[:200]}"
    env, f = None, exe
    if build == "tiered":
        f = work / f"{tid}.tier1"
        b = subprocess.run([zanec, "--tier-up", f, *pk(tid)], capture_output=True, text=True)
        if b.returncode: return tid, build, f"tier1 failed {b.stderr[:200]}"
        env = {**os.environ, "ZANE_TIER_UP": str(f), "ZANE_TIER_WAIT": "1"}
    r = subprocess.run(["valgrind", "-q", "--tool=callgrind", "--cache-sim=yes", "--branch-sim=yes", *run.CACHES,
                        f"--callgrind-out-file={prof}", exe, *args], capture_output=True, text=True, env=env)
    if r.returncode: return tid, build, f"run failed {r.returncode} {r.stderr[:200]}"
    e = run.totals(prof)
    l1 = e["I1mr"] + e["D1mr"] + e["D1mw"]; ll = e["ILmr"] + e["DLmr"] + e["DLmw"]; mp = e["Bcm"] + e["Bim"]
    return tid, build, (e["Ir"] + 10 * l1 + 100 * ll + 20 * mp, e["Ir"], mp, e["I1mr"], text(f))
jobs = [(t, b) for t in tests.TESTS if (Path(bench) / "bin" / t["id"]).is_dir() for b in ("optimized", "tiered")]
rows = []
with tempfile.TemporaryDirectory() as w, ThreadPoolExecutor(3) as pool:
    for tid, b, r in pool.map(lambda j: one(j[0], Path(w), j[1]), jobs):
        if isinstance(r, str): print(tid, b, "ERROR", r); continue
        print(tid, b, *r, flush=True); rows.append("\t".join([tid, b, *map(str, r)]) + "\n")
Path(__file__).parent.joinpath(f"{label}.tsv").write_text("program\tbuild\tcycles\tinstructions\tmispredicts\ti1_misses\ttext\n" + "".join(rows))
