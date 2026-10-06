"""Whether memory is reclaimed: each case runs a loop body 10,000 and
1,000,000 times and prints the exit status and peak RSS (KiB) of both runs.
A body that reclaims what it allocates shows the same peak at both sizes;
`control_push_grows` keeps everything it makes, and shows the measurement
can see growth. Usage: python3 reclaim.py [CASE...]"""
import subprocess, resource, sys, pathlib, tempfile
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
^Engine make(power Int) => Engine(power, String("made") + String("!"))
^Engine?^Engine risky(power Int) {
	abort Engine(power, String("aborted") + String("!"));
}
Int depth(c Count) => match (c) { n done => n; m more => depth(m) + Int(1); }
'''
cases={
"overwrite_settled": ("car Car(make(Int(0)));", "car = Car(make(i));"),
"overwrite_string": ("s String(\"x\");", "s = String(\"abc\") + String(\"def\");"),
"string_copy": ("s String(\"abcdefgh\") ; t String(\"\");", "t = s;"),
"ignored_result": ("", "make(i);"),
"inner_owner": ("", "e Engine = make(i);"),
"roaming_refill": ("keep Car(make(Int(0)));", "r ^Engine = make(i); keep = Car(r); r = make(i); keep = Car(r);"),
"aborted_owner": ("", "x ^Engine = risky(i) ? e { resolve e; }"),
"control_push_grows": ("l List<Car> = @primitives$List(Car);", "l!push(Car(make(i)));"),
"deep_copy": ("c Count = Count.more(Count.more(Count.more(Count.done(Int(1))))); d Count = c;", "d = c;"),
"list_elem_overwrite": ("l List<Car> = @primitives$List(Car); l!push(Car(make(Int(0))));", "l[Int(1)] = Car(make(i));"),
"string_concat_reset": ("s String(\"\"); k Int(0);", "s = s + String(\"a\"); k = k + Int(1); if(k == Int(64)) { s = String(\"\"); k = Int(0); }"),
"value_list_rebuild": ("l List<Int> = @primitives$List(Int);", "l = @primitives$List(Int); l!push(i); l!push(i);"),
}
only=sys.argv[1:] or list(cases)
for name in only:
    setup,body=cases[name]
    res=[]
    for n in (10000, 1000000):
        pkg=f"leak{name.replace('_','')}{n}"; d=work/pkg
        d.mkdir(parents=True,exist_ok=True)
        (d/"main.zn").write_text(f"package {pkg};\n{prelude}\n{types}\nUnit main() {{\n\t{setup}\n\ti Int(1);\n\ti!to(Int({n})) {{\n\t\t{body}\n\t}}\n\treturn Unit();\n}}\n")
        exe=str(work/(pkg+".exe"))
        r=subprocess.run([Z,"--build",exe,"--package",str(d)],capture_output=True,text=True)
        if r.returncode: res.append("build failed: "+(r.stdout+r.stderr).replace(str(work)+"/","")); break
        m=subprocess.run([sys.executable,"-c",f"import resource,subprocess;r=subprocess.run(['{exe}'],capture_output=True);print(r.returncode,resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss,r.stderr.decode()[:200])"],capture_output=True,text=True)
        res.append(f"N={n}: {m.stdout.strip()}")
    print(name, "|", " ; ".join(res))
