#!/usr/bin/env python3
"""perf.py ZANEC LABEL [prog...]: perf programs, optimized+tiered(+plain); cycles, Ir, mispredicts, I1 misses, .text."""
import importlib.machinery, importlib.util, os, shutil, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_loader("perfrun", importlib.machinery.SourceFileLoader("perfrun", str(ROOT / "tests/perf/run")))
run = importlib.util.module_from_spec(spec); spec.loader.exec_module(run)
def text(p):
    out = subprocess.run(["size","-A",str(p)],capture_output=True,text=True).stdout
    return sum(int(l.split()[1]) for l in out.splitlines() if l.startswith(".text"))
zanec, label, names = sys.argv[1], sys.argv[2], sys.argv[3:] or run.programs()
found = shutil.which("valgrind")
if not found: sys.exit("perf.py: valgrind is not on PATH")
valgrind = str(Path(found).resolve()).encode()
jobs = [(n,b) for n in names for b in (("optimized","tiered") if os.environ.get("ZANE_SKIP_PLAIN") else ("optimized","tiered","plain"))]
rows=[]
with tempfile.TemporaryDirectory() as work, ThreadPoolExecutor(3) as pool:
    work=Path(work)
    def one(j):
        n,b=j
        _,_,r,err=run.measure(zanec,n,b,work,valgrind,None)
        if err: return n,b,None,err
        f=work/(f"{n}.tier1" if b=="tiered" else f"{n}.{b}")
        e=run.totals(work/f"{n}.{b}.callgrind")
        ok=(run.GOLDEN/f"{n}.out").read_text()==r["output"]
        return n,b,(r["cycles"],r["instructions"],r["mispredicts"],e["I1mr"],text(f),ok),None
    for n,b,r,err in pool.map(one,jobs):
        if err: print(n,b,"ERROR",err[:300]); continue
        print(n,b,*r,flush=True); rows.append("\t".join([n,b,*map(str,r)])+"\n")
Path(sys.argv[0]).parent.joinpath(f"{label}.tsv").write_text("program\tbuild\tcycles\tinstructions\tmispredicts\ti1_misses\ttext\tgolden\n"+"".join(rows))
