"""compile_time.py MAIN NEW LANGBENCH CORE: median of five --optimize and
--tier-up build times of two zanec builds, alternating."""
import atexit, shutil, subprocess, time, statistics, sys, tempfile
from pathlib import Path
R = str(Path(__file__).resolve().parents[2])
if len(sys.argv) != 5: sys.exit(__doc__)
zmain, znew, bench, core = sys.argv[1:]
progs={"stress":f"{R}/tests/perf/stress","longChain":f"{R}/tests/codegen/fixtures/longChain","wideSum":f"{R}/tests/codegen/fixtures/wideSum",
 "binarytrees(langbench)":None}
def pk(n):
    if n.startswith("binarytrees"): return ["--package",f"binarytrees={bench}/bin/binarytrees","--package",f"bench={bench}/lib/bench","--package",f"core={core}/lib/core","--package",f"math={core}/lib/math"]
    return ["--package",progs[n]]
w=tempfile.mkdtemp()
atexit.register(shutil.rmtree, w, ignore_errors=True)
def t(z,args):
    s=time.perf_counter(); r=subprocess.run([z,*args],capture_output=True,text=True); e=time.perf_counter()-s
    return e if r.returncode==0 else None, r
for n in progs:
    for mode in ("--optimize","--tier-up"):
        res={}
        for lab,z in (("main",zmain),("new",znew)):res[lab]=[]
        for i in range(5):
            for lab,z in (("main",zmain),("new",znew)):
                out=f"{w}/{n}.{lab}"
                args=["--build",out,"--optimize",*pk(n)] if mode=="--optimize" else ["--tier-up",out+".so",*pk(n)]
                e,r=t(z,args)
                if e is None: print(n,mode,"fail",r.stderr[:150]); break
                res[lab].append(e)
            else: continue
            break
        if len(res["main"])==5 and len(res["new"])==5:
            m,nw=statistics.median(res["main"]),statistics.median(res["new"])
            print(f"{n:24}{mode:12} main {m:6.2f}s  new {nw:6.2f}s  {100*(nw/m-1):+5.1f}%",flush=True)
