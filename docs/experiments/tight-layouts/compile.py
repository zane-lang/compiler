#!/usr/bin/env python3
"""Compile time and executable size of every tests/perf program, per mode.

Run from the repository root after `pixi run just build`:

    pixi run -- python3 docs/experiments/tight-layouts/compile.py [RUNS]

Each program is built RUNS times (default 3) with and without --optimize
in each mode; the best wall time and the size of the stripped executable
are reported, summed over the programs, against the default build.

The ZANE_PACK and ZANE_UNSWITCH switches this script sets were removed in
2baf718 (PR 353); the compiler no longer reads them, so every mode builds
the same program. To reproduce, fetch the PR 353 branch (git fetch origin
pull/353/head) and check out 506bb97, the last commit that reads them
(0b88f63 removed them), and set ZANE_TIGHT_LAYOUTS_HISTORICAL=1. To compare
layouts on current main, build two compilers and use wall14.py.
"""
import os, subprocess, sys, tempfile, time
if os.environ.get("ZANE_TIGHT_LAYOUTS_HISTORICAL") != "1":
    sys.exit("error: ZANE_PACK/ZANE_UNSWITCH no longer exist; see the header of "
             + sys.argv[0] + ".\nSet ZANE_TIGHT_LAYOUTS_HISTORICAL=1 on 506bb97 to run.")

RUNS = int(sys.argv[1]) if len(sys.argv) > 1 else 3
ZANEC = os.path.abspath("_build/default/bin/zanec/zanec.exe")
MODES = [
    ("default", {}),
    ("default+unswitch", {"ZANE_UNSWITCH": "1"}),
    ("niche", {"ZANE_PACK": "niche"}),
    ("niche-unswitch", {"ZANE_PACK": "niche", "ZANE_UNSWITCH": "0"}),
]
programs = sorted(d for d in os.listdir("tests/perf") if os.path.isfile(f"tests/perf/{d}/main.zn"))
work = tempfile.mkdtemp()
totals = {}
for opt in ["", "--optimize"]:
    for name, extra in MODES:
        env = {k: v for k, v in os.environ.items() if k not in ("ZANE_PACK", "ZANE_UNSWITCH")}
        env.update(extra)
        t_sum = s_sum = 0
        for p in programs:
            out = f"{work}/{p}"
            best = 1e9
            for _ in range(RUNS):
                t = time.perf_counter()
                subprocess.run([ZANEC, "--build", out, *([opt] if opt else []), "--package", f"tests/perf/{p}"], env=env, check=True)
                best = min(best, time.perf_counter() - t)
            subprocess.run(["strip", "-o", out + ".s", out], check=True)
            t_sum += best
            s_sum += os.path.getsize(out + ".s")
        totals[(opt, name)] = (t_sum, s_sum)
        base = totals[(opt, "default")]
        print(f"{opt or 'plain':10} {name:17} {t_sum:7.2f}s ({100*(t_sum/base[0]-1):+5.1f}%)  {s_sum/1024:8.1f} KiB ({100*(s_sum/base[1]-1):+5.1f}%)", flush=True)
print(f"{len(programs)} programs: {' '.join(programs)}")
