#!/usr/bin/env python3
# One binary run with ZANE_POOL_REUSE off and on, alternately, N times each
# (default 15): checks both print the same, then reports user time (least
# and median), median system time and page faults. Usage:
#
#   N=21 python3 reuse_ab.py /tmp/zane-goose-variants/binarytrees.zane-pooled-peel-packed 18
exe, args = sys.argv[1], sys.argv[2:]
def run(env):
    pid = os.fork()
    if pid == 0:
        fd = os.open(os.devnull, os.O_WRONLY); os.dup2(fd, 1)
        os.execve(exe, [exe, *args], {**os.environ, **env})
    _, _, ru = os.wait4(pid, 0); return ru
outs = {k: subprocess.run([exe, *args], capture_output=True, text=True, env={**os.environ, "ZANE_POOL_REUSE": k}).stdout for k in "01"}
assert outs["0"] == outs["1"], "outputs differ"
res = {"0": [], "1": []}
for _ in range(int(os.environ.get("N", "15"))):
    for k in "01": res[k].append(run({"ZANE_POOL_REUSE": k}))
for k in "01":
    u = sorted(r.ru_utime for r in res[k]); s = sorted(r.ru_stime for r in res[k])
    print(f"reuse={k} user min {u[0]:.4f} median {statistics.median(u):.4f}  sys median {statistics.median(s):.4f}  faults {statistics.median(r.ru_minflt for r in res[k]):.0f}")
