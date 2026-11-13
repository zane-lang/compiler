#!/usr/bin/env python3
"""Build the Zane programs here with zanec and time them by the wall clock.

  time.py LABEL [PROGRAM ...]          build with --optimize, time, append
                                       to ../results/zane-LABEL.tsv
  time.py --pair LABEL VAR [PROGRAM ...]
                                       build each program twice, as it is and
                                       with VAR=0 in zanec's environment, and
                                       time the two in turn, run by run
  time.py --pair-run LABEL VAR [PROGRAM ...]
                                       build each program once and time it
                                       in turn as it is and with VAR=0 in
                                       the program's own environment
  time.py --show LABEL [LABEL ...]     print each label's times side by side

Run it in the pixi environment (`pixi run python3 ...`), which sets ZANE_CC.
`ZANEC` names another compiler; every other variable in the environment
reaches zanec as it is. TIME_SIZES (log2 bytes, by commas) and TIME_RUNS
change the sizes and the runs per size.

Each program prints `ready` once its data is built and a checksum when its
passes end. Output is flushed per line only to a terminal, so the program
runs on a pseudo-terminal, pinned to the last CPU, and the time between the
two lines is the loop's: building the data, which takes longer than the
loop at 2 GiB, is not in it. A size is run RUNS times and the best is kept.
Columns: program, log2 bytes of data, nanoseconds per operation, checksum,
each run's seconds. With --pair, the two builds' runs alternate, so a
neighbour on the machine slows both alike; they are written as LABEL and
LABEL-off. Every build of a program must print the same checksum at a size;
--show marks a row whose checksum differs from the first label's.
"""
import collections, os, pty, select, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
RESULTS = os.path.join(HERE, "..", "results")
# log2 of the operations in a pass, as model.c's run.py has them.
OPS = {"heavy": 23, "hash": 23, "gather": 23, "tree": 21, "chains": 21}
SIZES = [int(x) for x in os.environ.get("TIME_SIZES", "18,25,31").split(",")]
RUNS = int(os.environ.get("TIME_RUNS", "5"))


def build(program, out, env=None):
    zanec = os.environ.get("ZANEC", os.path.join(ROOT, "_build", "default", "bin", "zanec", "zanec.exe"))
    subprocess.check_call([zanec, "--build", out, "--optimize", "--package", os.path.join(HERE, program)],
                          env=env)


def timed(exe, args, env=None):
    """The seconds between `ready` and the checksum, and the checksum."""
    cpu = str(max(os.sched_getaffinity(0)))
    master, slave = pty.openpty()
    proc = subprocess.Popen(["taskset", "-c", cpu, exe, *args], stdout=slave, stderr=subprocess.STDOUT, env=env)
    os.close(slave)
    text, ready, lines = b"", None, []
    while True:
        select.select([master], [], [])
        try:
            chunk = os.read(master, 4096)
        except OSError:
            break
        if not chunk:
            break
        stamp = time.perf_counter()
        text += chunk
        while b"\n" in text:
            line, text = text.split(b"\n", 1)
            line = line.strip().decode()
            if line == "ready":
                ready = stamp
            elif line:
                lines.append((stamp, line))
    os.close(master)
    if proc.wait() != 0 or ready is None or not lines:
        sys.exit(f"{exe} {args}: exit {proc.returncode}, output {lines}")
    if lines[-1][0] <= ready:
        sys.exit(f"{exe} {args}: `ready` and the checksum came in one read, so the run has no time")
    return lines[-1][0] - ready, lines[-1][1]


def measure(labels, programs, variable=None, at_run=False):
    """Time each program's builds, one per label, in turn run by run: the
    first as zanec builds it, the second with `variable`=0."""
    os.makedirs(RESULTS, exist_ok=True)
    work = tempfile.mkdtemp()
    files = [open(os.path.join(RESULTS, f"zane-{label}.tsv"), "a") for label in labels]
    for program in programs:
        exes = []
        for k, label in enumerate(labels):
            exe = os.path.join(work, f"{program}-{k}")
            off = None if k == 0 else {**os.environ, variable: "0"}
            build(program, exe, None if at_run else off)
            exes.append(exe)
        for size in SIZES:
            times = [[] for _ in exes]
            sums = [set() for _ in exes]
            for _ in range(RUNS):
                for k, exe in enumerate(exes):
                    off = {**os.environ, variable: "0"} if at_run and k else None
                    seconds, checksum = timed(exe, [str(size), "1", str(OPS[program])], off)
                    times[k].append(seconds)
                    sums[k].add(checksum)
            for k, f in enumerate(files):
                if len(sums[k]) != 1:
                    sys.exit(f"{program} {size}: checksums differ between runs: {sums[k]}")
                ns = min(times[k]) * 1e9 / (1 << OPS[program])
                row = [program, str(size), f"{ns:.2f}", sums[k].pop(), *(f"{t:.4f}" for t in times[k])]
                f.write("\t".join(row) + "\n")
                f.flush()
                print(labels[k], *row, flush=True)


def show(labels):
    """Each label's best time per operation, and its median run in
    brackets, with the first label's over each other's."""
    rows = collections.defaultdict(dict)
    for label in labels:
        for line in open(os.path.join(RESULTS, f"zane-{label}.tsv")):
            program, size, ns, checksum, *runs = line.rstrip("\n").split("\t")
            seconds = sorted(float(r) for r in runs)
            median = seconds[len(seconds) // 2] * float(ns) / seconds[0]
            rows[(program, int(size))][label] = (float(ns), median, checksum)
    print("program  size  " + "  ".join(f"{l:>26}" for l in labels))
    for (program, size), got in sorted(rows.items()):
        first = got.get(labels[0])
        cells = []
        for l in labels:
            if l not in got:
                cells.append(f"{'-':>26}")
                continue
            ns, median, checksum = got[l]
            ratio = f" x{first[0] / ns:.2f} (x{first[1] / median:.2f})" if first and l != labels[0] else ""
            bad = " !" if first and checksum != first[2] else ""
            cells.append(f"{ns:8.2f}ns{ratio}{bad}".rjust(26))
        print(f"{program:8} 2^{size}  " + "  ".join(cells))


if __name__ == "__main__":
    if sys.argv[1] == "--show":
        show(sys.argv[2:])
    elif sys.argv[1] in ("--pair", "--pair-run"):
        label, variable = sys.argv[2], sys.argv[3]
        measure([label, label + "-off"], sys.argv[4:] or list(OPS), variable, sys.argv[1] == "--pair-run")
    else:
        measure([sys.argv[1]], sys.argv[2:] or list(OPS))
