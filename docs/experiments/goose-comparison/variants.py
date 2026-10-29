#!/usr/bin/env python3
# The measurements behind the "Pooled variants" and "Partial inlining"
# tables in README.md: binarytrees and treecopy built by this branch's zanec
# with each experiment's switch off and on, beside Goose's struct and
# pool-enum ports, each checked against tests.py's expected output and then
# timed. Run it inside the compiler's devbox (valgrind and clang):
#
#   devbox run -- python3 -u docs/experiments/goose-comparison/variants.py
#
# Paths come from the environment, as run.py's do. CORE is a `core`
# checkout's lib directory at the version this branch builds against.
import os, statistics, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
LB = os.environ.get("LANGBENCH", "/home/user/spec/langbench")
ZANEC = os.environ.get("ZANEC", os.path.join(HERE, "../../../_build/default/bin/zanec/zanec.exe"))
CORE = os.environ.get("CORE", "/tmp/claude-0/core-main/lib")
GOOSE = os.environ.get("GOOSE", "/tmp/claude-0/goose/goose-v2026.3-linux-x64/goose")
OUT = os.environ.get("WORK", "/tmp/zane-goose-variants")
RUNS = int(os.environ.get("RUNS", "9"))
sys.path.insert(0, LB)
import tests  # noqa: E402

# Each Zane variant and the switches it is built with.
ZANE = {
    "zane": {},
    "zane-peel": {"ZANE_PARTIAL_INLINE": "1"},
    "zane-pooled": {"ZANE_POOLED_VARIANTS": "1"},
    "zane-pooled-peel": {"ZANE_POOLED_VARIANTS": "1", "ZANE_PARTIAL_INLINE": "1"},
}
GOOSE_FORMS = {"goose": "", "goose-enum-pool": "_enum_pool"}
# Each test's measured depth, and how many of its trees are alive at the
# peak, which bytes per node divides by.
DEPTH = {"binarytrees": (16, 1), "treecopy": (18, 2)}

clang = subprocess.run(["which", "clang"], capture_output=True, text=True).stdout.strip()
os.makedirs(OUT, exist_ok=True)


def build(name, tid):
    exe = os.path.join(OUT, f"{tid}.{name}")
    if name in ZANE:
        cmd = [ZANEC, "--build", exe, "--optimize", "--package", f"{tid}={LB}/bin/{tid}",
               "--package", f"bench={LB}/lib/bench", "--package", f"core={CORE}/core",
               "--package", f"math={CORE}/math"]
        env = {**os.environ, **ZANE[name]}
    else:
        cmd = [GOOSE, "build", os.path.join(HERE, f"{tid}{GOOSE_FORMS[name]}.goose"), "-o", exe,
               "-O2", "--cc", clang]
        env = os.environ
    r = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if r.returncode != 0:
        sys.exit(f"build {name} {tid} failed:\n{r.stdout}{r.stderr}")
    return exe


def run(exe, args):
    t = time.perf_counter()
    pid = os.fork()
    if pid == 0:
        fd = os.open(os.devnull, os.O_WRONLY)
        os.dup2(fd, 1)
        os.execv(exe, [exe, *args])
    _, _, ru = os.wait4(pid, 0)
    return time.perf_counter() - t, ru


def instructions(exe, args):
    r = subprocess.run(["valgrind", "--tool=callgrind", "--callgrind-out-file=/dev/null", exe, *args],
                       capture_output=True, text=True)
    for line in r.stderr.splitlines():
        if "refs:" in line:
            return int(line.split()[-1].replace(",", ""))
    return 0


for test in tests.TESTS:
    tid = test["id"]
    if tid not in DEPTH:
        continue
    depth, alive = DEPTH[tid]
    nodes = lambda d: 2 ** (d + 1) - 1
    for name in [*ZANE, *GOOSE_FORMS]:
        exe = build(name, tid)
        for args, expected in [(test["check_args"], test["check_expected"]), (test["args"], test["expected"])]:
            out = subprocess.run([exe, *args], capture_output=True, text=True).stdout
            if out != expected:
                sys.exit(f"MISMATCH {name} {tid} {args}: {out!r} != {expected!r}")
        args = [str(depth)]
        run(exe, args)
        rs = [run(exe, args) for _ in range(RUNS)]
        wall = statistics.median(r[0] for r in rs)
        user = statistics.median(r[1].ru_utime for r in rs)
        faults = statistics.median(r[1].ru_minflt for r in rs)
        lo = min(run(exe, [str(depth - 1)])[1].ru_maxrss for _ in range(3))
        hi = min(run(exe, [str(depth)])[1].ru_maxrss for _ in range(3))
        per_node = (hi - lo) * 1024 / (nodes(depth) - nodes(depth - 1)) / alive
        print(f"{tid:12} {name:17} wall {wall:.4f}  user {user:.3f}  faults {faults:7.0f}  "
              f"instr {instructions(exe, args) / 1e6:7.0f}M  bytes/node {per_node:5.1f}", flush=True)
