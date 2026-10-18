"""Whether memory is reclaimed: each case runs a loop body 10,000 and
1,000,000 times and prints the exit status and peak RSS (KiB) of both runs.
A body that reclaims what it allocates shows the same peak at both sizes;
`control_push_grows` keeps everything it makes, and shows the measurement
can see growth.

With --check, the run fails unless every case built and exited 0, every case
but the control grew by at most RECLAIMED_SLACK_KIB from the small run to the
large one, and the control grew by at least CONTROL_GROWTH_KIB. Peak RSS
differs between machines, so the check compares a case's two runs with each
other, never with the numbers in reclaim.out. `just test-compiler` runs this.
Usage: python3 reclaim.py [--check] [CASE...]"""
import subprocess, resource, sys, pathlib, tempfile
CONTROL="control_push_grows"
# A body that reclaims stays within page-granularity noise of its small run
# (within about 120 KiB either way on the machines measured); the control grows by about 29 MiB.
RECLAIMED_SLACK_KIB=1024
CONTROL_GROWTH_KIB=16384
# ru_maxrss is KiB on Linux and bytes on macOS.
RSS_PER_KIB=1024 if sys.platform=="darwin" else 1
here=pathlib.Path(__file__).resolve().parent
Z=str(here.parent.parent/"_build/default/bin/zanec/zanec.exe")
src=(here/"copies/main.zn").read_text()
prelude=src[src.index("alias Int"):src.index("type Pair")]
work=pathlib.Path(tempfile.mkdtemp())
types='''
type Engine = #struct { power Int; label String; }
Engine(power Int, label String) => init{ power; label; }
type Car = #struct { engine Engine; }
Car(engine ^Engine) => init{ engine; }
type Count = variant { done Int; more Count; }
^Engine make(power Int) => Engine(power, @operators$concat(String("made"), String("!")))
^Engine?^Engine risky(power Int) {
	abort Engine(power, @operators$concat(String("aborted"), String("!")));
}
Int depth(c Count) => match (c) { n done => n; m more => @operators$add(depth(m), Int(1)); }
'''
cases={
"overwrite_settled": ("car Car(make(Int(0)));", "car = Car(make(i));"),
"overwrite_string": ("s String(\"x\");", "s = @operators$concat(String(\"abc\"), String(\"def\"));"),
"string_copy": ("s String(\"abcdefgh\") ; t String(\"\");", "t = s;"),
"ignored_result": ("", "make(i);"),
"inner_owner": ("", "e Engine = make(i);"),
"roaming_refill": ("keep Car(make(Int(0)));", "r ^Engine = make(i); keep = Car(r); r = make(i); keep = Car(r);"),
"aborted_owner": ("", "x ^Engine = risky(i) ? e { resolve e; }"),
"control_push_grows": ("l List<Car> = @primitives$List(Car);", "l!push(Car(make(i)));"),
"deep_copy": ("c Count = Count.more(Count.more(Count.more(Count.done(Int(1))))); d Count = c;", "d = c;"),
"list_elem_overwrite": ("l List<Car> = @primitives$List(Car); l!push(Car(make(Int(0))));", "l[Int(1)] = Car(make(i));"),
"string_concat_reset": ("s String(\"\"); k Int(0);", "s = @operators$concat(s, String(\"a\")); k = @operators$add(k, Int(1)); if(@operators$equal(k, Int(64))) { s = String(\"\"); k = Int(0); }"),
"value_list_rebuild": ("l List<Int> = @primitives$List(Int);", "l = @primitives$List(Int); l!push(i); l!push(i);"),
}
args=sys.argv[1:]
check=bool(args) and args[0]=="--check"
if check: args=args[1:]
only=args or list(cases)
failures=[]
for name in only:
    setup,body=cases[name]
    res=[]; peaks=[]
    for n in (10000, 1000000):
        pkg=f"leak{name.replace('_','')}{n}"; d=work/pkg
        d.mkdir(parents=True,exist_ok=True)
        (d/"main.zn").write_text(f"package {pkg};\n{prelude}\n{types}\nUnit main() {{\n\t{setup}\n\ti Int(1);\n\ti!to(Int({n})) {{\n\t\t{body}\n\t}}\n\treturn Unit();\n}}\n")
        exe=str(work/(pkg+".exe"))
        r=subprocess.run([Z,"--build",exe,"--package",str(d)],capture_output=True,text=True)
        if r.returncode: res.append("build failed: "+(r.stdout+r.stderr).replace(str(work)+"/","")); break
        m=subprocess.run([sys.executable,"-c","import resource,subprocess,sys;r=subprocess.run([sys.argv[1]],capture_output=True);print(r.returncode,resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss,r.stderr.decode()[:200])",exe],capture_output=True,text=True)
        res.append(f"N={n}: {m.stdout.strip()}")
        fields=m.stdout.split()
        if len(fields)>=2 and fields[0]=="0": peaks.append(int(fields[1])//RSS_PER_KIB)
    print(name, "|", " ; ".join(res))
    if not check: continue
    if len(peaks)<2:
        failures.append(f"{name}: did not build and exit 0 at both sizes")
        continue
    growth=peaks[1]-peaks[0]
    if name==CONTROL and growth<CONTROL_GROWTH_KIB:
        failures.append(f"{name}: grew {growth} KiB, under {CONTROL_GROWTH_KIB}, so the measurement cannot see growth")
    elif name!=CONTROL and growth>RECLAIMED_SLACK_KIB:
        failures.append(f"{name}: grew {growth} KiB, over {RECLAIMED_SLACK_KIB}, so it does not reclaim")
for f in failures: print("FAIL", f)
sys.exit(1 if failures else 0)
