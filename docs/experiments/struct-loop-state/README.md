# Loop state in a struct local

Loop state held in a struct local should run as fast as the same state in
plain locals. A struct that owns a block (one with a list member) is held in
its scope's frame, so a counter kept in one of its members is a frame word
LLVM loads and stores on every pass. Two fixes are compared here, one against
the other and both against `main`:

- **#398, `perf/frame-shadow`** (525512b): codegen's `Frame_shadow` keeps any
  frame slot in a register copy and writes it back only before something may
  read it.
- **The split, `perf/split-struct-locals`** (this branch): in stage 5,
  `Known_calls` writes a worker's step out where it runs, and `Split_holds`
  splits a held struct whose every use names a member into a local per
  member, so scalar members never reach the frame.

`main` is 9b8ba95. LangArena is the `zane` port at 69673fa of the LangArena
repo.

## How to measure

Wall time decides. Callgrind counts only confirm what a wall result suggests.
Every run below is pinned to one core (`taskset -c 2`). Each round runs every
binary once in a fresh random order, and each ratio is the median over rounds
of a binary's time over `main`'s in the same round, so drift between rounds
cancels. `[p25, p75]` is the spread of those ratios.

- `build-variants.sh TAG COMPILERDIR` builds the LangArena port once per
  Brainfuck::Array variant in `brainfuck/` (`locals`, `worker`, `counted`)
  into `$OUT/la-TAG-VARIANT`. Each binary is the whole arena; only the
  Brainfuck file differs.
- `measure.py ROUNDS OUT.csv BIN...` times Brainfuck::Array alone.
- `fullarena.py ROUNDS OUT.csv BIN...` times all 50 benchmarks per run.
- `buildperf.sh` (with `MAIN`, `FS`, `SPLIT` set to checkouts) builds every
  `tests/perf` program optimized with each; `perfwall.py ROUNDS OUT.csv`
  times them at the sizes in `results/perf-sizes.json`, and
  `perfreport.py OUT.csv` summarises.

The raw CSVs are in `results/`.

## Step 1: #398, register copies of frame slots

**Design.** `lib/codegen/frame_shadow.ml`: stores write the register copy
only and are written back before a call that may read the slot; a list's
count-and-room pair stored as one `<2 x i32>` keeps the count's copy; a
frame placed on two paths, and one entered inline, are frames too. See the
PR body of #398 for the full list.

**Results.** On #398 itself, by instructions (Callgrind) and min-of-25 wall:
worker −13.0% instructions and −7.7% wall, counted −9.6% instructions but
+2.3% wall. The counted loop became the locals loop instruction for
instruction; the wall gap was code layout.

## Step 2: the split

**Design.** The user's question: why not rewrite struct state as locals in
the CGT, so the IR is the same as the locals version's?
`lib/optimize/split_holds.ml` does it for a hold whose every use is a
member's address, an assignment to a member or a read of one. Block-owning
members stay held alone, with the part of the struct's layout they cover.
The worker case needed `lib/optimize/known_calls.ml`: `work`'s loop calls the
step through a function value, so the step's writes to the subject are in a
function of its own until LLVM inlines it, too late for the split. Known
calls writes out a call of a known function value, and a small call given
one, as an expansion.

**Results.** Callgrind, Brainfuck::Array counted: locals 21.35G, split
21.58G instructions (+1.1%, one load of the jumps count left). The hot
loop is otherwise the locals loop.

Moving code around alone moves this benchmark by up to ±10% wall
(`-align-all-nofallthru-blocks=N`, tried through a temporary, uncommitted
`ZANE_LLVM_ARGS` hook), so the struct-vs-locals gap in wall time below is
largely layout, not work.

## Step 3: the final 1-vs-1 (2026-11-19)

Split at eef37b3, #398 at 525512b, `main` at 9b8ba95; all three with the
full test suite passing.

**Brainfuck::Array**, 20 rounds (`results/brainfuck-final.csv`):

| version | main median | split / main | #398 / main | split / #398 |
| --- | --- | --- | --- | --- |
| locals (control) | 1.438 s | 0.981 [0.951, 1.035] | 1.014 [0.960, 1.089] | 0.984 [0.952, 1.009] |
| struct + worker | 1.895 s | 0.919 [0.892, 0.961] | 0.917 [0.884, 0.956] | 0.993 [0.962, 1.026] |
| struct + counted | 1.952 s | 0.963 [0.923, 0.987] | 0.989 [0.952, 1.000] | 0.975 [0.944, 1.004] |

Struct over locals, same compiler: `main` 1.335 worker and 1.342 counted;
#398 1.195 and 1.296; split 1.230 and 1.282. Each run's noise is about ±4%.
On this benchmark the two are tied.

**`tests/perf`**, 46 programs, 10 rounds (`results/perf-final.csv`):

- #398: geometric mean 0.978 against `main`. Outside ±2% over its whole
  spread: `interp` 0.857, `rotations` 0.862, `subjects` 0.857, `paths`
  0.930.
- Split: geometric mean 0.999; nothing outside ±2%. `subjects` 0.960
  [0.943, 1.031]; `workers` 1.046 [0.975, 1.064], slower than expected and
  not yet looked into.

**Full LangArena**, 50 benchmarks, worker variant, 6 rounds
(`results/arena-final.csv`, `fullarena.py`); every checksum passed in every
run:

| | geometric mean | outside ±2% over the whole spread |
| --- | --- | --- |
| #398 / main | 0.984 | faster: Brainfuck::Recursion 0.721, Base64::Decode 0.883, Distance::Jaro 0.900, Brainfuck::Array 0.923, Hash::SHA256 0.952, Json::ParseDom 0.958, Binarytrees::Arena 0.959 |
| split / main | 1.004 | slower: Brainfuck::Recursion 1.141, Etc::Sieve 1.041 |
| split / #398 | 1.009 | Brainfuck::Recursion 1.645, Etc::Words 1.155, Distance::Jaro 1.108, Matmul::T8 1.064, Etc::Sieve 1.036; Maze::AStar 0.919 |

Brainfuck::Recursion is a regression of the split against `main` (+14%),
not yet looked into: its interpreter is the likeliest place for a call
written out by `Known_calls` to cost more than it saves.

## Step 4: the Brainfuck::Recursion regression

**Design.** Each pass switched off on its own, through temporary switches
in `optimize.ml` that are not committed (`ZANE_TMP_NO_KNOWN=1` skips
`Known_calls`, `ZANE_TMP_NO_SPLIT=1` skips `Split_holds`), each build of
the worker arena timed on Brainfuck::Recursion alone (`BENCH=...
measure.py`), 15 rounds (`results/recursion-passes.csv`).

**Results.**

| build | median | vs main |
| --- | --- | --- |
| main | 2.086 s | 1 |
| #398 | 1.422 s | 0.694 [0.654, 0.767] |
| split, both passes | 2.368 s | 1.126 [1.102, 1.200] |
| split without `Known_calls` | 2.016 s | 0.990 [0.948, 1.037] |
| `Known_calls` without `Split_holds` | 2.481 s | 1.207 [1.167, 1.285] |

Writing the step out costs the 20%; the split wins part of it back. The
interpreter's struct nests another (`tape`), and the split splits both.
The optimized IR of a driver calling `runRecursive` alone has about the
same loop with and without `Known_calls` (365 against 371 instructions in
looping blocks, 79 loads each), so Callgrind is checking whether it is work
or placement.

## Reading so far

The two changes look complementary rather than competing. The split helps
only scalar members of a held struct, and only where every use names a
member. #398 keeps any frame slot in a register, including the count and
room of a list held in the frame, which the split leaves there (why #398
wins `subjects`), and slots of programs with no struct to split at all
(`interp`, `rotations`, `paths`). On Brainfuck::Array, where both apply,
they tie. The full arena agrees: #398 is ahead overall (0.984 against
0.999-1.004 for the split), on benchmarks with no struct to split. The open question for the user is whether to land both, not
which one.

## What remains

- Brainfuck::Recursion +14% and Etc::Sieve +4% on the split: find which
  pass costs it, and fix or narrow it.
- Why the split reads slower on `workers`.
- The repo's perf gate (`just test-perf`, Valgrind against `main`) on the
  split.
- If both land: the split rebased on #398 and measured together.
- Whether to open the split's PR, close #398 or keep both: the user's call.
