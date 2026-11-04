#!/usr/bin/env python3
"""Estimated cycles (tests/perf/run's formula and caches) of each program in
dev/bench/memo/programs, in each build the two levers touch, without tables,
with them, and with each lever:

    plain      unoptimized, no tiers
    optimized  --optimize
    tier0      --tiered, run without tier 1, so it stays wholly in tier 0
    tiered     --tiered, tier 1 loaded before `main` (ZANE_TIER_WAIT=1)

A variant is `base` (--no-memoize), `memo`, `preserve` (ZANE_MEMO_PRESERVE=1)
or `route` (ZANE_MEMO_ROUTE=1). Every variant of every build must print
what the plain build without tables prints, or the script exits 1. Run
inside `devbox run`:

    measure.py ZANEC OUT PROGRAM_DIR...

A run Callgrind has not finished after TIMEOUT seconds (1800 by default)
is reported as an error.
"""
import json, os, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ZANEC, OUT, DIRS = sys.argv[1], Path(sys.argv[2]), [Path(d) for d in sys.argv[3:]]
if len({d.name for d in DIRS}) != len(DIRS):
    sys.exit("each PROGRAM_DIR needs a name of its own: outputs are named by it")
TIMEOUT = float(os.environ.get("TIMEOUT", "1800"))
CACHES = ["--I1=32768,8,64", "--D1=32768,8,64", "--LL=8388608,16,64"]
OUT.mkdir(parents=True, exist_ok=True)
BUILDS = {"plain": [], "optimized": ["--optimize"], "tier0": ["--tiered"], "tiered": ["--tiered"]}
VARIANTS = {"base": {}, "memo": {}, "preserve": {"ZANE_MEMO_PRESERVE": "1"}, "route": {"ZANE_MEMO_ROUTE": "1"}}
WHICH = {"plain": ["base", "memo", "preserve"], "optimized": ["base", "memo", "preserve"],
         "tier0": ["base", "memo", "route"], "tiered": ["base", "memo", "preserve", "route"]}

def totals(profile):
    events = None
    for line in profile.read_text().splitlines():
        if line.startswith("events:"):
            events = line.split()[1:]
        elif line.startswith("summary:"):
            return dict(zip(events, map(int, line.split()[1:])))

def one(job):
    d, build, variant = job
    stem = OUT / f"{d.name}.{build}.{variant}"
    flags = BUILDS[build] + (["--no-memoize"] if variant == "base" else [])
    env = {k: v for k, v in os.environ.items() if k not in ("ZANE_TIER_UP", "ZANE_TIER_WAIT")}
    env.update({"ZANE_MEMO_PRESERVE": "0", "ZANE_MEMO_ROUTE": "0", **VARIANTS[variant]})
    b = subprocess.run([ZANEC, "--build", stem, *flags, "--package", d], capture_output=True, text=True, env=env)
    if b.returncode:
        return job, {"error": b.stderr[-300:]}
    run_env = dict(env)
    if build == "tiered":
        lib = Path(f"{stem}.tier1")
        b = subprocess.run([ZANEC, "--tier-up", lib, *flags[1:], "--package", d], capture_output=True, text=True, env=env)
        if b.returncode:
            return job, {"error": b.stderr[-300:]}
        run_env.update({"ZANE_TIER_UP": str(lib), "ZANE_TIER_WAIT": "1"})
    args = (d / "arguments").read_text().split()
    prof = Path(f"{stem}.cg")
    try:
        r = subprocess.run(["valgrind", "-q", "--tool=callgrind", "--cache-sim=yes", "--branch-sim=yes", *CACHES,
                            f"--callgrind-out-file={prof}", stem, *args], capture_output=True, text=True, env=run_env,
                           timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return job, {"error": f"Callgrind ran past {TIMEOUT:g} s"}
    if r.returncode:
        return job, {"error": r.stderr[-300:]}
    e = totals(prof)
    cycles = e["Ir"] + 10 * (e["I1mr"] + e["D1mr"] + e["D1mw"]) + 100 * (e["ILmr"] + e["DLmr"] + e["DLmw"]) + 20 * (e["Bcm"] + e["Bim"])
    return job, {"cycles": cycles, "instructions": e["Ir"], "output": r.stdout}

jobs = [(d, b, v) for d in DIRS for b in BUILDS for v in WHICH[b]]
with ThreadPoolExecutor(int(os.environ.get("JOBS", "4"))) as ex:
    res = dict(ex.map(one, jobs))
rows = []
wrong = False
print(f"{'program':<12}{'build':<10}{'base':>14}{'memo':>14}{'lever':>9}{'lever cyc':>14}{'memo/base':>11}{'lever/base':>11}{'lever/memo':>11}  same")
for d in DIRS:
    for b in BUILDS:
        for lever in WHICH[b][2:]:
            x, y, z = (res[(d, b, v)] for v in ("base", "memo", lever))
            if any("error" in r for r in (x, y, z)):
                print(f"{d.name:<12}{b:<10} ERROR", [r.get("error", "") for r in (x, y, z)])
                continue
            same = x["output"] == y["output"] == z["output"] == res[(d, "plain", "base")].get("output")
            wrong = wrong or not same
            print(f"{d.name:<12}{b:<10}{x['cycles']:>14,}{y['cycles']:>14,}{lever:>9}{z['cycles']:>14,}"
                  f"{(y['cycles']-x['cycles'])/x['cycles']:>+11.2%}{(z['cycles']-x['cycles'])/x['cycles']:>+11.2%}"
                  f"{(z['cycles']-y['cycles'])/y['cycles']:>+11.2%}  {same}")
            rows.append({"program": d.name, "build": b, "lever": lever, "base": x["cycles"], "memo": y["cycles"],
                         "lever_cycles": z["cycles"], "same": same})
(OUT / "results.json").write_text(json.dumps(rows, indent=1))
if wrong:
    sys.exit("a variant printed differently from the plain build without tables")
