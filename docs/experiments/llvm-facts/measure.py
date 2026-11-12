#!/usr/bin/env python3
"""Measure every perf program's optimized and tiered builds with the
switches in the environment, using tests/perf/run's own build-and-measure
code, and write LABEL.tsv: program, build, cycles, instructions, mispredicts,
.text bytes (the executable's for optimized, tier 1's library's for tiered),
and whether the output matched golden.

    measure.py LABEL [program ...]          # e.g. ZANE_UNROLL_PARTIAL=150 measure.py up150
"""
import importlib.machinery, importlib.util, os, shutil, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
spec = importlib.util.spec_from_loader("perfrun", importlib.machinery.SourceFileLoader("perfrun", str(ROOT / "tests/perf/run")))
run = importlib.util.module_from_spec(spec); spec.loader.exec_module(run)

def text_size(path):
    out = subprocess.run(["size", "-A", str(path)], capture_output=True, text=True).stdout
    return sum(int(l.split()[1]) for l in out.splitlines() if l.startswith(".text"))

def main():
    label, names = sys.argv[1], sys.argv[2:] or run.programs()
    zanec = os.environ.get("ZANEC") or ROOT / "_build/default/bin/zanec/zanec.exe"
    valgrind = str(Path(shutil.which("valgrind")).resolve()).encode()
    jobs = [(n, b) for n in names for b in ("optimized", "tiered")]
    rows = []
    with tempfile.TemporaryDirectory() as work, ThreadPoolExecutor(os.cpu_count() or 1) as pool:
        work = Path(work)
        def one(job):
            n, b = job
            name, build, r, err = run.measure(zanec, n, b, work, valgrind, None)
            if err:
                return n, b, None, err
            f = work / (f"{n}.tier1" if b == "tiered" else f"{n}.{b}")
            ok = (run.GOLDEN / f"{n}.out").read_text() == r["output"]
            return n, b, (r["cycles"], r["instructions"], r["mispredicts"], text_size(f), ok), None
        for n, b, r, err in pool.map(one, jobs):
            if err:
                print(n, b, "ERROR", err[:500]); rows.append(f"{n}\t{b}\tERROR\t\t\t\t\n"); continue
            print(n, b, *r, flush=True)
            rows.append("\t".join([n, b, *map(str, r)]) + "\n")
    (HERE / "results").mkdir(exist_ok=True)
    (HERE / "results" / f"{label}.tsv").write_text("program\tbuild\tcycles\tinstructions\tmispredicts\ttext\tgolden\n" + "".join(rows))

main()
