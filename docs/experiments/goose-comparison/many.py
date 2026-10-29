import os, sys, statistics
# Interleaved user-time comparison: runs each executable with ARG, N times
# (default 9), alternating the order, and prints least and median user time.
#
#   python3 many.py 18 build-a/binarytrees build-b/binarytrees
arg, exes = sys.argv[1], sys.argv[2:]
res = {e: [] for e in exes}
for i in range(int(os.environ.get("N", "9"))):
    for exe in (exes if i % 2 == 0 else exes[::-1]):
        pid = os.fork()
        if pid == 0:
            fd = os.open(os.devnull, os.O_WRONLY); os.dup2(fd, 1); os.execv(exe, [exe, arg])
        _, _, ru = os.wait4(pid, 0); res[exe].append(ru.ru_utime)
for e in exes: print(f"{os.path.basename(e):40} least {min(res[e]):.3f}  median {statistics.median(res[e]):.3f}")
