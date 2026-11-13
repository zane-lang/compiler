#!/usr/bin/env python3
"""The memory the sparse program holds, with and without a runtime switch.

  sparse.py LABEL VAR LISTS EACH [EACH ...]
      build ../programs/sparse once, run it with LISTS lists of EACH 8-byte
      elements, as it is and with VAR=0 in its environment, and read
      /proc/PID/smaps_rollup once it prints `ready`; append to
      ../results/sparse-LABEL.tsv

Columns: lists, elements per list, on or off, the bytes the elements use,
then Rss, AnonHugePages and Anonymous from smaps_rollup in kB. Extra
environment (ZANE_HUGE_MIN, say) reaches the program as it is.
"""
import os, pty, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
RESULTS = os.path.join(HERE, "..", "results")


def rollup(pid):
    got = {}
    for line in open(f"/proc/{pid}/smaps_rollup"):
        parts = line.split()
        if len(parts) >= 2 and parts[0].endswith(":"):
            got[parts[0][:-1]] = parts[1]
    return [got["Rss"], got["AnonHugePages"], got["Anonymous"]]


def main(label, variable, lists, eaches):
    # Each pass reads one of the first 1024 elements of every list.
    if any(int(e) < 1024 for e in eaches):
        sys.exit("sparse.py: each list needs at least 1024 elements")
    zanec = os.environ.get("ZANEC", os.path.join(ROOT, "_build", "default", "bin", "zanec", "zanec.exe"))
    exe = os.path.join(tempfile.mkdtemp(), "sparse")
    subprocess.check_call([zanec, "--build", exe, "--optimize", "--package", os.path.join(HERE, "sparse")])
    os.makedirs(RESULTS, exist_ok=True)
    out = open(os.path.join(RESULTS, f"sparse-{label}.tsv"), "a")
    for each in eaches:
        for mode in ("on", "off"):
            env = {k: v for k, v in os.environ.items() if k != variable}
            if mode == "off":
                env[variable] = "0"
            # Output is flushed per line only to a terminal, so the program
            # runs on one, as in time.py, and is stopped once read.
            master, slave = pty.openpty()
            proc = subprocess.Popen([exe, lists, each, "1000000000"], stdout=slave, stderr=subprocess.STDOUT, env=env)
            os.close(slave)
            line = os.read(master, 4096).strip()
            if line != b"ready":
                sys.exit(f"sparse {lists} {each}: {line!r}")
            row = [lists, each, mode, str(int(lists) * int(each) * 8), *rollup(proc.pid)]
            proc.kill()
            proc.wait()
            os.close(master)
            out.write("\t".join(row) + "\n")
            out.flush()
            print(*row, flush=True)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:])
