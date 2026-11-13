#!/usr/bin/env python3
"""Time whole runs of the Zane programs here, process start to exit, with
and without a runtime switch, the two in turn run by run.

  whole.py LABEL VAR [PROGRAM ...]   build each program once and run it in
                                     turn as it is and with VAR=0 in its
                                     environment; append to
                                     ../results/whole-LABEL.tsv
  whole.py --show LABEL              each size's medians and the break-even

time.py times the loop alone, between the program's `ready` and its
checksum. Here the clock starts before the process is made and stops when
it has exited, so building the data and giving its memory back are in it;
`ready` still splits the run into building and the loop. Which of the two
goes first alternates from run to run, so neither always follows the
other's freeing of 2 GiB.

WHOLE_FRAGMENT names a build of fragment.c beside this: before each run,
the page cache is dropped and that program is started and left holding its
scattered pages until the run has ended, so every run, with the switch and
without, starts on free memory with few free 2 MiB blocks (fragment.c says
how few).
TIME_SIZES (log2 bytes, by commas), TIME_RUNS,
and WHOLE_PASSES (the program's passes argument, default 1) change what is
run. Run it in the pixi environment, as time.py.

Columns: program, log2 bytes, on or off, run, then seconds for the whole
run, building (start to `ready`), the loop (`ready` to the checksum) and
the end (checksum to exit), the system CPU seconds and minor faults of the
process, and the deltas of /proc/vmstat's thp_fault_alloc,
thp_fault_fallback, compact_stall, compact_fail and compact_success over
the run (the machine's, not only the process's), the checksum, and the
passes (absent from rows written before it was added, which made one).
"""
import collections, os, pty, select, statistics, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
RESULTS = os.path.join(HERE, "..", "results")
OPS = {"heavy": 23, "hash": 23, "gather": 23, "tree": 21, "chains": 21}
SIZES = [int(x) for x in os.environ.get("TIME_SIZES", "21,22,23,24,25,26,27,28,29,30,31").split(",")]
RUNS = int(os.environ.get("TIME_RUNS", "7"))
PASSES = os.environ.get("WHOLE_PASSES", "1")
VMSTAT = ["thp_fault_alloc", "thp_fault_fallback", "compact_stall", "compact_fail", "compact_success"]


def vmstat():
    got = {}
    for line in open("/proc/vmstat"):
        name, value = line.split()
        got[name] = int(value)
    return [got.get(n, 0) for n in VMSTAT]


def build(program, out):
    zanec = os.environ.get("ZANEC", os.path.join(ROOT, "_build", "default", "bin", "zanec", "zanec.exe"))
    subprocess.check_call([zanec, "--build", out, "--optimize", "--package", os.path.join(HERE, program)])


def run(exe, args, env):
    """Seconds of the whole run, building, the loop and the end; system
    seconds and minor faults; the checksum."""
    cpu = str(os.cpu_count() - 1)
    master, slave = pty.openpty()
    before = vmstat()
    start = time.perf_counter()
    proc = subprocess.Popen(["taskset", "-c", cpu, exe, *args], stdout=slave, stderr=subprocess.STDOUT, env=env)
    os.close(slave)
    text, ready, last = b"", None, None
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
                last = (stamp, line)
    _, status, usage = os.wait4(proc.pid, 0)
    end = time.perf_counter()
    proc.returncode = os.waitstatus_to_exitcode(status)
    after = vmstat()
    os.close(master)
    if proc.returncode != 0 or ready is None or last is None:
        sys.exit(f"{exe} {args}: exit {proc.returncode}, output {last}")
    times = [end - start, ready - start, last[0] - ready, end - last[0]]
    return times, usage.ru_stime, usage.ru_minflt, [a - b for a, b in zip(after, before)], last[1]


def fragmented():
    """The fragmenter, holding its pages, or None."""
    exe = os.environ.get("WHOLE_FRAGMENT")
    if not exe:
        return None
    subprocess.run(["sync"])
    with open("/proc/sys/vm/drop_caches", "w") as f:
        f.write("3\n")
    proc = subprocess.Popen([exe], stdout=subprocess.PIPE)
    line = proc.stdout.readline()
    if not line.startswith(b"fragmented"):
        sys.exit(f"fragment: {line!r}")
    return proc


def measure(label, variable, programs):
    os.makedirs(RESULTS, exist_ok=True)
    work = tempfile.mkdtemp()
    out = open(os.path.join(RESULTS, f"whole-{label}.tsv"), "a")
    for program in programs:
        exe = os.path.join(work, program)
        build(program, exe)
        for size in SIZES:
            sums = set()
            for r in range(RUNS):
                for mode in (("on", "off") if r % 2 == 0 else ("off", "on")):
                    env = {**os.environ, variable: "0"} if mode == "off" else None
                    held = fragmented()
                    try:
                        times, stime, minflt, deltas, checksum = run(exe, [str(size), PASSES, str(OPS[program])], env)
                    finally:
                        if held:
                            held.kill()
                            held.wait()
                    sums.add(checksum)
                    row = [program, str(size), mode, str(r), *(f"{t:.4f}" for t in times), f"{stime:.3f}",
                           str(minflt), *map(str, deltas), checksum, PASSES]
                    out.write("\t".join(row) + "\n")
                    out.flush()
                    print(*row, flush=True)
            if len(sums) != 1:
                sys.exit(f"{program} {size}: checksums differ: {sums}")


def show(label):
    """Per program and size: the median and best whole run each way, the
    medians of building and of the loop, the runs that stalled, and the
    passes a program must make before the loop's gain pays for building."""
    rows = collections.defaultdict(lambda: {"on": [], "off": []})
    for line in open(os.path.join(RESULTS, f"whole-{label}.tsv")):
        f = line.rstrip("\n").split("\t")
        # Rows written before the pass count was a column made one pass.
        passes = int(f[16]) if len(f) > 16 else 1
        rows[(f[0], int(f[1]), passes)][f[2]].append([float(x) for x in f[4:9]] + [int(x) for x in f[9:15]])
    med = lambda xs: statistics.median(xs)
    print("program size  passes  whole on/off median (best)        build on-off  loop on/off   stalls  passes to pay")
    # Runs with different pass counts are kept apart, each with its own line.
    for (program, size, passes), got in sorted(rows.items()):
        on, off = got["on"], got["off"]
        col = lambda rs, i: [r[i] for r in rs]
        build = med(col(on, 1)) - med(col(off, 1))
        gain = med(col(off, 2)) - med(col(on, 2))
        stalls = sum(1 for r in on if r[8] > 0)
        worst = max(col(on, 1)) - med(col(off, 1))
        # The loop's gain is over all of a run's passes; the break-even is
        # counted in single passes.
        pay = "now" if build <= 0 else (f"{build * passes / gain:.1f}" if gain > 0 else "never")
        print(f"{program:7} 2^{size} x{passes} {med(col(on, 0)):7.3f}/{med(col(off, 0)):7.3f} "
              f"({min(col(on, 0)):.3f}/{min(col(off, 0)):.3f})  {build:+7.3f}  "
              f"{med(col(on, 2)):.4f}/{med(col(off, 2)):.4f}  {stalls}/{len(on)} worst {worst:+.2f}  {pay}")


if __name__ == "__main__":
    if sys.argv[1] == "--show":
        show(sys.argv[2])
    else:
        measure(sys.argv[1], sys.argv[2], sys.argv[3:] or list(OPS))
