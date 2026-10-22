#!/usr/bin/env python3
"""Time each build mode from the compile's start: to the program's first line, and to its exit."""
import os, subprocess, sys, time, statistics
Z = os.environ.get("ZANEC", os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../_build/default/bin/zanec/zanec.exe"))
pkg, arg = sys.argv[1], sys.argv[2]
modes = sys.argv[3].split(",") if len(sys.argv) > 3 else ["plain", "o2", "full"]
reps = int(os.environ.get("REPS", "3"))
HERE = os.path.dirname(os.path.abspath(__file__))

def run_prog(exe, t0, env=None):
    import pty
    master, slave = pty.openpty()
    p = subprocess.Popen([exe, arg], stdout=slave, env=env)
    os.close(slave)
    first = None; out = b""
    while True:
        try: chunk = os.read(master, 4096)
        except OSError: break
        if not chunk: break
        if first is None: first = time.monotonic() - t0
        out += chunk
    p.wait(); os.close(master)
    out = out.replace(b"\r\n", b"\n")
    return first, time.monotonic() - t0, out

def mode(m, exe):
    t0 = time.monotonic()
    env = dict(os.environ)
    if m == "plain":
        subprocess.run([Z, "--build", exe, "--package", pkg], check=True)
        return run_prog(exe, t0)
    if m in ("o2", "full", "o2nr", "fullnr"):
        if m.startswith("o2"): env["ZANE_NO_FOLD"] = "1"
        if m.endswith("nr"): env["ZANE_LLVM_ARGS"] = "-unroll-runtime=false"
        subprocess.run([Z, "--build", exe, "--optimize", "--package", pkg], check=True, env=env)
        return run_prog(exe, t0)
    if m.startswith("tier"):
        # tier:<flavour>: tier 0 plain, tier 1 built while it runs.
        flavour = m.split(":")[1]
        return tiered(exe, t0, flavour)
    raise SystemExit(m)

def tiered(exe, t0, flavour):
    so = exe + ".tier1.so"
    for f in (so,):
        if os.path.exists(f): os.unlink(f)
    e1 = dict(os.environ, ZANE_TIER="1")
    if flavour.startswith("o2"): e1["ZANE_NO_FOLD"] = "1"
    if flavour.endswith("nr"): e1["ZANE_LLVM_ARGS"] = "-unroll-runtime=false"
    builder = subprocess.Popen([os.path.join(HERE, "tier1.sh"), Z, pkg, so], env=e1)
    env = dict(os.environ, ZANE_TIER="0")
    subprocess.run([Z, "--build", exe, "--package", pkg, "--link", os.path.join(HERE, "tier.o")], check=True, env=env)
    r = run_prog(exe, t0, dict(os.environ, ZANE_TIER_UP=so))
    builder.kill(); builder.wait()
    return r

out0 = None
for m in modes:
    firsts, totals = [], []
    for i in range(reps):
        f, t, out = mode(m, os.path.join(HERE, "bin-" + m.replace(":", "-")))
        if out0 is None: out0 = out
        assert out == out0, (m, out, out0)
        firsts.append(f); totals.append(t)
    print(f"{m:10s} first line {statistics.median(firsts)*1000:7.0f} ms   total {statistics.median(totals)*1000:7.0f} ms", flush=True)
