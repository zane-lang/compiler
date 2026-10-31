"""Least and median CPU time (user + system) and peak memory of each binary,
run in turn N times (default 11) with the same arguments:

    N=21 python3 time_runs.py "ARGS" BINARY ...
"""
import os, sys, statistics
args = sys.argv[1].split(); exes = sys.argv[2:]
def run(exe):
    pid = os.fork()
    if pid == 0:
        fd = os.open(os.devnull, os.O_WRONLY); os.dup2(fd, 1); os.execv(exe, [exe, *args])
    _, _, ru = os.wait4(pid, 0); return ru.ru_utime + ru.ru_stime, ru.ru_maxrss
res = {e: [] for e in exes}
for _ in range(int(os.environ.get("N", "11"))):
    for e in exes: res[e].append(run(e))
for e in exes:
    t = sorted(r[0] for r in res[e]); print(f"{e:40s} {t[0]:.3f} / {statistics.median(t):.3f} s  {max(r[1] for r in res[e])/1024:.0f} MB")
