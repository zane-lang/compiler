"""Each test's instructions per function, Zane against Goose and C.

A test's total time hides a mechanism Zane does worse whenever it wins
elsewhere in the same program: binarytrees' `check` ran less than half
Goose's instructions while its `make` ran more. This runs every test's
Zane, Goose and C binary under Callgrind, whose counts are the same run to
run, at a size small enough to profile, and lines up each function's own
instructions (self cost) across the three. A row is flagged when Zane's
count is more than THRESHOLD over the better of the other two, counting a
language only where its whole program runs fewer instructions than Zane's,
the function takes at least SHARE of Zane's total, and the program runs at
least SMALLEST.

    python3 mechanisms.py BIN [TEST ...]

BIN holds `<test>.zane`, `<test>.goose` and `<test>.c`, as run.py's
WORK/bin does. Writes `mechanisms.md` and `mechanisms.json` beside BIN and
prints the Markdown. Functions are matched by name with the package, the
signature, Callgrind's recursion marker (`'2`), Goose's `_g` suffix,
underscores and case taken away, and `zane_main` read as `main`; a function
one language inlines is a row the others leave empty. The C library's and
the runtime's functions are rows of their own.
"""
import concurrent.futures, json, os, re, subprocess, sys, tempfile

# The size each test is profiled at: small enough for Callgrind, large
# enough that the program's own loops dominate its start.
SIZES = {
    "startup": [], "primes": [], "trialdiv": ["1000000"], "binarytrees": ["14"],
    "mandelbrot": ["400"], "fannkuch": ["9"], "entities": ["300000"],
    "listgrowth": ["500000"], "ntree": ["8"], "treecopy": ["14"], "nbody": ["200000"],
    "spectralnorm": ["300"], "allocfree": ["200000"],
    "particles": ["5000"], "concscan": ["300000"],
}
LANGS = ["zane", "goose", "c"]
THRESHOLD = float(os.environ.get("THRESHOLD", "1.10"))
SHARE = float(os.environ.get("SHARE", "0.05"))
# A program below this many instructions is mostly the C library starting,
# whose counts move with the environment (valgrind-instruction-counts).
SMALLEST = 10_000_000

LINE = re.compile(r"^\s*([\d,]+) \([^)]*\)\s+(.*?):(.*?) \[(.*)\]\s*$")


def name(fn):
    """A function's name as the three languages are matched by."""
    fn = re.sub(r"'\d+$", "", fn)
    fn = re.sub(r"\(.*\)$", "", fn)
    fn = fn.split("$")[-1]
    fn = fn.split("@@")[0]
    if fn == "zane_main":
        fn = "main"
    if fn.endswith("_g"):
        fn = fn[:-2]
    return fn.replace("_", "").lower()


def profile(binary, args):
    """Self instructions per function, and the total."""
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, "cg")
        subprocess.run(["valgrind", "--tool=callgrind", "--callgrind-out-file=" + out, binary] + args,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        text = subprocess.run(["callgrind_annotate", "--threshold=100", "--inclusive=no", out],
                              capture_output=True, text=True).stdout
    total, funcs = 0, {}
    for line in text.splitlines():
        if "PROGRAM TOTALS" in line:
            total = int(line.split()[0].replace(",", ""))
            continue
        m = LINE.match(line)
        if not m:
            continue
        count, fn = int(m.group(1).replace(",", "")), m.group(3)
        if fn.startswith("0x"):
            continue
        key = name(fn)
        funcs[key] = funcs.get(key, 0) + count
    return total, funcs


def test(bin_dir, t):
    runs = {}
    for lang in LANGS:
        binary = os.path.join(bin_dir, f"{t}.{lang}")
        if os.path.exists(binary):
            runs[lang] = profile(binary, SIZES.get(t, []))
    return t, runs


def amount(n):
    return f"{n / 1e6:.1f} M" if n >= 1e5 else f"{n / 1e3:.0f} K"


def table(t, runs):
    zane_total = runs.get("zane", (0, {}))[0]
    keys = set()
    for _, funcs in runs.values():
        keys |= {k for k, v in funcs.items() if v >= 0.01 * max(1, zane_total)}
    rows, flags = [], []
    for k in sorted(keys, key=lambda k: -max(runs[l][1].get(k, 0) for l in runs)):
        counts = {l: runs[l][1].get(k) for l in runs}
        z = counts.get("zane")
        # A language's count is a reference only when its whole program runs
        # fewer instructions than Zane's: C's `main` is small in allocfree
        # because its allocating is `malloc`'s rows, not because it does less.
        others = [v for l, v in counts.items() if l != "zane" and v and runs[l][0] < zane_total]
        best = min(others) if others else None
        flag = bool(z and best and z > THRESHOLD * best and z >= SHARE * zane_total and zane_total >= SMALLEST)
        if flag:
            flags.append(k)
        cells = [amount(counts[l]) if counts.get(l) else "—" for l in LANGS if l in runs]
        ratio = f"{z / best:.2f}" if z and best and z >= 0.01 * zane_total else "—"
        rows.append(f"| {'**' + k + '**' if flag else k} | " + " | ".join(cells) + f" | {ratio} |")
    head = "| function | " + " | ".join(l for l in LANGS if l in runs) + " | Zane ÷ best |"
    total = "| total | " + " | ".join(f"{runs[l][0] / 1e6:.1f} M" for l in LANGS if l in runs) + " | " + (
        f"{zane_total / min(runs[l][0] for l in runs if l != 'zane'):.2f}" if len(runs) > 1 and zane_total else "—") + " |"
    args = " ".join(SIZES.get(t, [])) or "no argument"
    md = [f"### {t} ({args})", "", head, "|" + " --- |" * (len(runs) + 2), total] + rows + [""]
    return "\n".join(md), flags


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    bin_dir = sys.argv[1]
    tests = sys.argv[2:] or list(SIZES)
    with concurrent.futures.ProcessPoolExecutor(os.cpu_count()) as pool:
        results = dict(pool.map(test, [bin_dir] * len(tests), tests))
    out, flagged, data = [], {}, {}
    for t in tests:
        md, flags = table(t, results[t])
        out.append(md)
        if flags:
            flagged[t] = flags
        data[t] = {l: {"total": tot, "functions": f} for l, (tot, f) in results[t].items()}
    summary = ["## Flagged", ""] + (
        [f"- {t}: " + ", ".join(fs) for t, fs in flagged.items()] or ["- none"]) + [""]
    text = "\n".join([f"# Instructions per function ({bin_dir})", "",
                      f"Flagged: Zane over {THRESHOLD:.2f}× the better of Goose and C in a function "
                      f"that takes at least {SHARE:.0%} of Zane's total, against a language only "
                      f"where its whole program runs fewer instructions than Zane's, in programs of "
                      f"{SMALLEST // 1_000_000} M instructions or more.", ""] + summary + out)
    where = os.path.dirname(os.path.abspath(bin_dir.rstrip("/")))
    with open(os.path.join(where, "mechanisms.md"), "w") as f:
        f.write(text)
    with open(os.path.join(where, "mechanisms.json"), "w") as f:
        json.dump(data, f, indent=1)
    print(text)


if __name__ == "__main__":
    main()
