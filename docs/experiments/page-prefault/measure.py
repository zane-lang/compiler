#!/usr/bin/env python3
"""Minor page faults and wall time of each tests/perf program, built with
--optimize. Usage: measure.py [--env K=V ...] [--runs N] [--out FILE] [PROGRAM...]

Each program is built once into _build/page-prefault/, then run N times
(default 5) with its `arguments`; the fault count is the run's own
(getrusage of the child, so it is the same on every run), the time the best
of the N. `automaton`, whose library needs its own object, is left out."""
import argparse, os, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PERF = ROOT / "tests" / "perf"
WORK = ROOT / "_build" / "page-prefault"


def run(exe, args, env):
    t = time.perf_counter()
    p = subprocess.Popen([exe, *args], stdout=subprocess.DEVNULL, env=env)
    _, status, ru = os.wait4(p.pid, 0)
    wall = time.perf_counter() - t
    if status:
        return None
    return wall, ru.ru_minflt, ru.ru_maxrss


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--env", action="append", default=[])
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--scale", type=float, default=1,
                    help="multiply each integer argument by this (0 gives the startup floor)")
    ap.add_argument("--zanec", default=str(ROOT / "_build/default/bin/zanec/zanec.exe"))
    ap.add_argument("--reuse", action="store_true", help="run the executables the last call built")
    ap.add_argument("programs", nargs="*")
    a = ap.parse_args()
    env = dict(os.environ, **dict(kv.split("=", 1) for kv in a.env))
    names = a.programs or sorted(
        d.name for d in PERF.iterdir()
        if (d / "main.zn").exists() and not (d / "lib").exists())
    WORK.mkdir(parents=True, exist_ok=True)
    print("program\tfaults\tbest_s\tmaxrss_kb")
    for n in names:
        exe = WORK / n
        b = subprocess.CompletedProcess([], 0) if a.reuse and exe.exists() else subprocess.run([a.zanec, "--build", exe, "--optimize", "--package", PERF / n],
                           capture_output=True, text=True)
        if b.returncode:
            print(f"{n}\tbuild failed", file=sys.stderr)
            continue
        args = (PERF / n / "arguments").read_text().split() if (PERF / n / "arguments").exists() else []
        args = [str(max(1, int(int(x) * a.scale))) if x.lstrip("-").isdigit() else x for x in args]
        rs = [run(exe, args, env) for _ in range(a.runs)]
        if None in rs:
            print(f"{n}\trun failed", file=sys.stderr, flush=True)
            continue
        print(f"{n}\t{rs[0][1]}\t{min(r[0] for r in rs):.4f}\t{rs[0][2]}", flush=True)


main()
