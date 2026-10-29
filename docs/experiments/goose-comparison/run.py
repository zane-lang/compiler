"""Builds each langbench test in Zane, Goose and C, checks the output, and
times it: one untimed run, then RUNS timed runs; reports median wall time,
spread and peak RSS. Run inside the zane compiler's devbox (clang 19)."""
import json, os, resource, statistics, subprocess, sys, time

# Where each piece lives, overridable from the environment: the spec repo's
# langbench, a zanec built at the langbench's language version (v0.20 when
# this ran), the core package's lib/ at the matching version (v0.5), the
# Goose compiler, and a scratch directory for binaries and results. A
# "zane-base" column runs prebuilt binaries from WORK/bin-base, when present.
HERE = os.path.dirname(os.path.abspath(__file__))
LB = os.environ.get("LANGBENCH", "/home/user/spec/langbench")
ZANEC = os.environ.get("ZANEC", "/tmp/claude-0/zanec-v020/_build/default/bin/zanec/zanec.exe")
CORE = os.environ.get("CORE", "/tmp/claude-0/core/lib")
GOOSE = os.environ.get("GOOSE", "/tmp/claude-0/goose/goose-v2026.3-linux-x64/goose")
WORK = os.environ.get("WORK", HERE)
OUT = os.path.join(WORK, "bin")
RUNS = int(os.environ.get("RUNS", "5"))
QUICK = "--quick" in sys.argv
sys.path.insert(0, LB)
import tests  # noqa: E402

clang = subprocess.run(["which", "clang"], capture_output=True, text=True).stdout.strip()
os.makedirs(OUT, exist_ok=True)

def build(lang, tid):
    exe = os.path.join(OUT, f"{tid}.{lang}")
    if lang == "zane-base":
        return os.path.join(WORK, "bin-base", f"{tid}.zane"), 0.0
    if lang == "zane":
        cmd = [ZANEC, "--build", exe, "--optimize", "--package", f"{tid}={LB}/bin/{tid}",
               "--package", f"bench={LB}/lib/bench", "--package", f"core={CORE}/core",
               "--package", f"math={CORE}/math"]
    elif lang.startswith("goose"):
        form = lang[len("goose"):].replace("-", "_")
        cmd = [GOOSE, "build", os.path.join(HERE, f"{tid}{form}.goose"), "-o", exe,
               "-O2", "--cc", clang]
    else:
        cmd = ["clang", "-O2", "-o", exe, f"{LB}/c/{tid}.c", "-lm", "-lpthread"]
    t = time.perf_counter()
    r = subprocess.run(cmd, capture_output=True, text=True)
    dt = time.perf_counter() - t
    if r.returncode != 0:
        sys.exit(f"build {lang} {tid} failed:\n{r.stdout}{r.stderr}")
    return exe, dt

def run_once(exe, args):
    t = time.perf_counter()
    p = subprocess.Popen([exe, *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    out, err = p.communicate()
    dt = time.perf_counter() - t
    _, status, ru = os.wait4(p.pid, 0) if False else (None, p.returncode, None)
    return out.decode(), dt

def run_measured(exe, args):
    # wait4 gives the child's own peak RSS
    t = time.perf_counter()
    pid = os.fork()
    if pid == 0:
        fd = os.open(os.devnull, os.O_WRONLY)
        os.dup2(fd, 1)
        os.execv(exe, [exe, *args])
    _, status, ru = os.wait4(pid, 0)
    dt = time.perf_counter() - t
    return dt, ru.ru_maxrss

results = {}
langs = ["zane-base"] if os.path.isdir(os.path.join(WORK, "bin-base")) else []
langs += ["zane", "goose", "goose-enum-ref", "goose-enum-pool", "c"]
# ONLY=a,b runs just those tests.
only = os.environ.get("ONLY")
for test in tests.TESTS:
    tid = test["id"]
    if only and tid not in only.split(","):
        continue
    args = test["check_args"] if QUICK else test["args"]
    expected = test["check_expected"] if QUICK else test["expected"]
    row = {}
    for lang in langs:
        # A Goose form other than the main port runs where it has a file.
        if lang.startswith("goose-") and not os.path.exists(
                os.path.join(HERE, f"{tid}{lang[len('goose'):].replace('-', '_')}.goose")):
            continue
        exe, bt = build(lang, tid)
        out, _ = run_once(exe, args)
        if out != expected:
            print(f"MISMATCH {lang} {tid}: {out!r} != {expected!r}")
            row[lang] = {"build": bt, "error": "mismatch"}
            continue
        times, rss = [], 0
        if not QUICK:
            run_measured(exe, args)
            for _ in range(RUNS):
                dt, m = run_measured(exe, args)
                times.append(dt)
                rss = max(rss, m)
        else:
            times = [0.0]
        row[lang] = {"build": bt, "median": statistics.median(times),
                     "min": min(times), "max": max(times), "rss_kb": rss}
        print(f"{tid:13} {lang:15} build {bt:6.2f}s  median {row[lang]['median']:8.4f}s "
              f"[{min(times):.4f}-{max(times):.4f}]  rss {rss/1024:8.1f} MB", flush=True)
    results[tid] = row
with open(os.path.join(WORK, "quick.json" if QUICK else "results.json"), "w") as f:
    json.dump(results, f, indent=1)
