#!/usr/bin/env python3
"""The spec repository's langbench Zane programs, built against `core` in
each mode, timed and checked against langbench's expected output.

Run from the compiler's root after `pixi run just build`:

    python3 docs/experiments/tight-layouts/langbench.py LANGBENCH CORE [RUNS] [TEST...]

LANGBENCH is the spec repository's langbench/ directory and CORE a
checkout of zane-lang/core. Each program is built with --optimize, as
`zane build` builds it, and run RUNS times (default 5) at langbench's
size; the best wall time is reported against the default build.
"""
import importlib.util, os, subprocess, sys, tempfile, time

bench, core = (os.path.abspath(a) for a in sys.argv[1:3])
runs = int(sys.argv[3]) if len(sys.argv) > 3 else 5
only = sys.argv[4:]
spec = importlib.util.spec_from_file_location("tests", os.path.join(bench, "tests.py"))
tests = importlib.util.module_from_spec(spec); spec.loader.exec_module(tests)
ZANEC = os.path.abspath("_build/default/bin/zanec/zanec.exe")
MODES = [("default", {}), ("default+unswitch", {"ZANE_UNSWITCH": "1"}), ("niche", {"ZANE_PACK": "niche"})]
work = tempfile.mkdtemp()
print(f"{'test':14}" + "".join(f"{m:>26}" for m, _ in MODES), flush=True)
for t in tests.TESTS:
    tid = t["id"]
    if only and tid not in only: continue
    if not os.path.isdir(os.path.join(bench, "bin", tid)): continue
    cells, base = [], None
    for name, extra in MODES:
        env = {k: v for k, v in os.environ.items() if k not in ("ZANE_PACK", "ZANE_UNSWITCH")}
        env.update(extra)
        out = os.path.join(work, f"{tid}-{name.replace('+', '-')}" + (".exe" if sys.platform == "win32" else ""))
        b = subprocess.run([ZANEC, "--build", out, "--optimize",
                            "--package", f"{tid}={bench}/bin/{tid}", "--package", f"bench={bench}/lib/bench",
                            "--package", f"core={core}/lib/core", "--package", f"math={core}/lib/math"],
                           env=env, capture_output=True, text=True)
        if b.returncode != 0:
            cells.append("refused"); print(b.stderr[:400], file=sys.stderr); continue
        best, ok = 1e9, True
        for _ in range(runs):
            s = time.perf_counter()
            r = subprocess.run([out, *t["args"]], capture_output=True, text=True, timeout=600)
            best = min(best, time.perf_counter() - s)
            ok = ok and r.returncode == 0 and r.stdout.replace("\r\n", "\n") == t["expected"]
        if base is None: base = best
        cells.append(f"{best:8.3f}s {100*(best/base-1):+6.1f}%{'' if ok else ' WRONG'}")
    print(f"{tid:14}" + "".join(f"{c:>26}" for c in cells), flush=True)
