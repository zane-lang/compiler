#!/usr/bin/env python3
"""Build model.c, sweep it, write results/LABEL.tsv, print the summary.

  run.py LABEL [KERNEL ...]     measure (minutes; pins to the last CPU)
  run.py --sweep LABEL KERNEL ...  every size from 2^16 to 2^28, 4 KiB pages
  run.py --show LABEL           print the summary of a saved run

Columns: kernel, log2 bytes of data, huge pages, variant, parameter,
ns per operation (best of 3), checksum. Variants of one kernel must agree
on the checksum; the run stops if they do not.
"""
import os, subprocess, sys, tempfile, collections

HERE = os.path.dirname(os.path.abspath(__file__))
KERNELS = {"gather": 23, "heavy": 23, "scatter": 23, "hash": 23, "bsearch": 21, "tree": 21,
           "twohop": 23, "nested": 23, "chains": 21, "combo": 21, "gatherx": 23, "heavyx": 23}
SIZES = [18, 25, 31]
SWEEP = list(range(16, 29))

def measure(label, kernels, sweep=False):
    exe = os.path.join(tempfile.mkdtemp(), "model")
    subprocess.check_call(["clang", "-O2", "-pthread", "-o", exe, os.path.join(HERE, "model.c")])
    allowed = sorted(os.sched_getaffinity(0))
    cpu = str(allowed[-1])
    # The helper kernels pin a second thread: give it another allowed CPU,
    # chosen here, before taskset narrows the main thread's set.
    if len(allowed) < 2:
        sys.exit("run.py needs two CPUs: the helper variants run a second thread on its own CPU")
    env = dict(os.environ, HELPER_CPU=str(allowed[-2]))
    out = os.path.join(HERE, "results", label + ".tsv")
    with open(out, "a") as f:
        for k in kernels:
            for size in (SWEEP if sweep or k.endswith('x') else [25, 31] if '.' in k else SIZES):
                for huge in ((0,) if sweep else (0, 1)):
                    text = subprocess.check_output(["taskset", "-c", cpu, exe, k, str(size), str(KERNELS[k.split('.')[0]]), str(huge)], text=True, env=env)
                    sums = {l.split("\t")[6] for l in text.splitlines()}
                    if len(sums) != 1:
                        sys.exit(f"checksums differ: {k} {size} {huge}")
                    f.write(text); f.flush()
                    print(k, size, huge, "done", flush=True)
    return out

def show(label):
    rows = collections.defaultdict(dict)
    for l in open(os.path.join(HERE, "results", label + ".tsv")):
        k, size, huge, v, p, ns, _ = l.split("\t")
        best = rows[(k, int(size), int(huge))]
        if v not in best or float(ns) < best[v][0]:
            best[v] = (float(ns), p)
    for (k, size, huge), best in sorted(rows.items()):
        base = best["base"][0]
        cells = [f"{v} {ns:.1f}ns x{base / ns:.2f}" + (f" (p={p})" if p != "0" else "")
                 for v, (ns, p) in best.items() if v != "base"]
        print(f"{k:8} 2^{size} huge={huge} base {base:7.1f}ns | " + " | ".join(cells))

if __name__ == "__main__":
    if sys.argv[1] == "--show":
        show(sys.argv[2])
    elif sys.argv[1] == "--sweep":
        measure(sys.argv[2], sys.argv[3:], sweep=True)
        show(sys.argv[2])
    else:
        measure(sys.argv[1], sys.argv[2:] or list(KERNELS))
        show(sys.argv[1])
