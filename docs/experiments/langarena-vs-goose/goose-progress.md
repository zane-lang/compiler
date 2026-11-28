# Closing the Goose gap: progress

Working state for the overnight run (user's request 2026-11-14: bring every
Zane / Goose gap down, worst first, all in one session). Kept current and
committed as each step lands, so it survives a context compaction.

## Setup

- Compiler: `/home/user/compiler`, branch `perf/zane-vs-goose` (pushed).
  zane-lang/compiler#377 (perf/zane-vs-c) is in the merge queue; its fixes are
  cherry-picked here.
- Port build: `env $SW LANGARENA=… sh docs/experiments/langarena-vs-goose/build.sh OUT` with
  `SW="ZANE_LOOP_REGS=1 ZANE_ASSIGN_MOVES=1 ZANE_VERSION_CALLS=1 ZANE_LENT_OWNERS=1 ZANE_FRAME_SHADOW=1 ZANE_MERGE_CHECKS=1 ZANE_ENDLESS=1 ZANE_SIZED_TBAA=1 ZANE_FRAME_SCOPES=1"`.
- Checks: `ZANE_CHECK=1 BIN ../test.js` from `zane/` (all 50), then
  `just test-compiler` in the compiler.
- Timing: `tri.py ROUNDS NAME=BIN…` (pinned to CPU 2, interleaved). Goose
  binaries: scratchpad `gb/goose_gcc`, `gb/goose_clang` (rebuild: `goose/`
  Makefile `prod`, Goose v2026.4).
- Profile: `prof/sampler.so` (LD_PRELOAD), `prof/symbolize.py`.
- Rule (memory `zane-perf-fix-in-compiler`): fix the compiler or library, not
  the port; the port may take Goose's structure where that is the design,
  not a dodge.

## Baseline (step 19, `results/step19-goose.json`)

Zane / Goose-clang 1.31 geomean. Worst: LZWDecode 6.2, Sort::Self 5.8,
CSV::Parse 4.0, Calculator::Ast 3.9, LZWEncode 3.2, LogParser 2.4, SHA256 2.4,
HuffDecode 2.3, BWTEncode 2.0, NGram 1.9, Binarytrees::Arena 1.8,
Maze::Generator 1.8, Words 1.7, Interpreter 1.6, Sort::Merge 1.5.

## Log

- Compiler branch also has `core` changes: `/home/user/core` branch
  `perf/zane-vs-goose` (pushed; add_repo zane-lang/core with push access).

### LZWDecode: 0.87 → 0.37 s (Goose/clang 0.14; 6.2× → 2.6×)

- Goose: every entry's bytes in one byte array, an entry a slice into it;
  no allocation per entry, appends are memcpy; the result is a byte list.
- Port now has that layout (`List<U8>` strings + starts/lengths) and gives
  back a `List<U8>` (a String only for the final checksum compare).
- A byte loop was 1.5 s (bounds + room check + count store per byte), so:
  compiler 4d88987 + core cc30133: `List.appendRange(from, start, count)`
  and `appendOwn(start, count)`, one `zane_list_append` copy, elements
  that own no blocks only (fixtures `listAppend`, `reject/appendOwners`).
- Left: ~3.2 MB/iteration of list growth copies under 1 MiB (doublings).
  Tried making a list past 256 KiB an oversized growable block at once:
  0.58 s, worse (a mapping per iteration); reverted.


### Sort::Self: 1.98 → 0.33 s (Goose/clang 0.34; 5.8× → 1.0×)

- Port sorted with C's `qsort` (comparator through a pointer) via the arena
  FFI; Goose's std `sort` is a pdqsort with a branchless Lomuto partition.
- Compiler + core: `List.sort()` for I32/I64/U8, runtime `zane_list_sort`,
  the same algorithm written out per width (fixtures `listSort`,
  `reject/sortFloats`). Port: copy the data, `sort()`, as Goose's port.

### CSV::Parse: 1.89 → 0.72 s (Goose/clang 0.47; 4.0× → 1.5×)

- Port parsed through the arena FFI's C reader with glibc `strtod` (52%
  of the time). Goose reads with its std `csv::each_record` and its own
  `parse_flt` over slices. Port now has that structure: one Zane pass over
  the bytes, each float field parsed where it lies.
- Compiler 1a23e7c + core 912d211: `zane_parse_f64` checks and folds
  the digits in one pass, with Clinger's fast path (≤19 digits, ≤2^53,
  ≤22 after the point: one exact division) before `strtod`;
  `String.parseFloat(start, count)` reads a range with no copy (fixture
  `parseRange`).
- Left: the scan is ~2 cycles/byte against Goose's ~1. Goose's reader
  runs a tight inner loop per field kind (`while` with 3 compares); Zane
  has only counted loops (`to`/`repeat`), no `while`/`break`, so the
  port toggles a quote flag per byte. A conditional loop is a language
  decision → question for the user.

### Calculator::Ast: 0.41 → 0.19 s (Goose/clang 0.11); Interpreter 0.48 → 0.425 (Goose 0.445)

- Goose's AST names are slices of the input (`p.input[start..pos]`), and
  its interpreter's dictionary is keyed by `const u8[:]`. Port had a
  String per name (`slice` → an allocation, a held block, a free, a
  Node move) and read bytes through the FFI `Buffer`.
- Port now: `Name { start; length }` in the nodes, the parser reads its
  String with `byteAt`, and the interpreter uses `SliceMap`
  (`arena/maps.zn`), StringMap's slots keyed by ranges of the one text.
- Left (Ast): `whitespace` is 35%, nearly all of it IRCE's safe-range
  setup for a loop that runs 0–1 times (`i!to(bound)` stands for a
  `while`). Without IRCE: 0.133 s.
- IRCE measured (`ZANE_NO_IRCE_BUILD=1`, and `ZANE_TRY_LLVM` for options;
  both experiment switches, out before any PR). Off: geomean 0.987, Ast
  0.70, BFS 0.84, but Matmul::T8 1.15, GameOfLife 1.17, BWTEncode 1.11.
  `-irce-min-eliminated-checks=40` (default 10): Ast 0.71 but Maze::AStar
  1.32, Template::Regex 1.28, Maze::BFS 1.24, geomean 1.021. No global
  setting wins; the default stays. A fix needs IRCE to skip a short
  search loop (an exit on loaded data) and keep counted ones.

### LZWEncode: 1.46 → 0.72 s (Goose/clang 0.51; 3.2× → 1.4×)

- Goose: every string a slice of one growing byte array (`new_string`,
  `concat` append there), its dictionary keyed by slices, hashed by
  lanes and compared by `memeq`. Port had String concatenation and a
  StringMap; now has that layout with `BytesMap` (`arena/maps.zn`) keyed
  by ranges of a `List<U8>`, sized for every code (≤65536).
- Byte-at-a-time hash and compare in Zane were 90%, so compiler 9b72f6d
  + core 0ca5428: `List.sameRange` (one memcmp) and `List.hashRange` (four
  lanes over 32-byte blocks, the tail read with fixed loads, no memcpy
  call); integers only (fixtures `listRanges`, `reject/rangeFloats`).
- Left: the hash (one per lookup, three per miss, as Goose) and cache
  misses on the slot and the stored key, which Goose has too.

### LogParser (2.4×): not attempted

- Port uses PCRE2 JIT through the arena FFI, as C's entry does (72% in
  JIT code). Goose has its own regex engine: literal-pair prefilters
  (`gs_find_pair`, `gs_scan_pair_tables`) and a DFA (`regex_find_end`).
  Closing it needs a regex library for Zane: a library project, left.

### SHA256: 0.78 → 0.75 s (Goose/clang 0.33, gcc 0.57); open

- Port now as Goose's: `List<U8>` data, `Array<I32, 8>` hashes with
  wrapping 32-bit arithmetic (CRC32 shares the list).
- Goose/clang: unrolled by 8, `i % 8` folds to constants, the 8 hashes
  live in two xmm registers (SLP). Ours: unrolled by 4, hashes stay in a
  stack array, the index computed (`&0x1c`) and each lane a store→load.
  `-unroll-count=8` and `-unroll-runtime-epilog=true` (ZANE_TRY_LLVM) do
  not change it: the unrolled loop's start alignment is not known, so
  the index does not fold. Needs the IR read; left open.

### HuffDecode: 1.33 → 1.20–1.25 s (Goose/clang 0.58); open

- Port read the encoded bytes and pushed each decoded byte through the
  FFI `Buffer` (a foreign call per byte). Now as Goose's: `byteAt` on
  the String, a `List<U8>` out, given back as bytes (a String only for
  the final compare).
- Reading the node once before the left/right choice (so it can be a
  select) was slower, 1.34: the predicted branch beats the select on the
  load chain. Goose: branchless child offset from the bit, the 8-bit loop
  fully unrolled, a leaf flag byte, node pointers (no index scaling).
  Ours: `b!to(min(8, remaining))` is not unrolled, the leaf test reads two
  fields. Whole bytes in a constant `b!to(8)` loop (the last byte after)
  was slower too, 1.30. Left open.

### BWTEncode (2.0×): open

- Same rounds as Goose (prefix doubling to n). Goose sorts each round
  with its std `stable_sort`, an adaptive natural merge sort with a
  comparator over rank pairs: the suffix array is already in rank order
  from the round before, so its runs are long. Ours: two full counting
  sorts per round, as C. 32-bit counts: no change. Matching Goose needs a
  comparator (or key-pair) stable sort in core; left.

## Re-measure (step 20, `results/step20-goose.json`, before NGram)

Zane / Goose-clang 1.15 geomean (was 1.31), faster on 15; Zane /
Goose-gcc 0.94 (was 1.08), faster on 26. Worst vs clang now: LZWDecode
2.8, LogParser 2.5, SHA256 2.2, HuffDecode 2.1, BWTEncode 1.9, NGram 1.8,
Binarytrees::Arena 1.8, Ast 1.7, Words 1.7, CSV 1.6, Sort::Merge 1.6,
Maze::Generator 1.5, Template::Parse 1.5, LZWEncode 1.4.

### NGram: 0.57 → 0.244 s (Goose/clang 0.31; 1.8× → 0.8×)

- Port probed its IntMap 2 times per gram of the first string and 4 per
  gram of the second (get, put, has, get), each probe starting with a
  `rem` division, and read bytes through the arena FFI. Goose: one
  probe per gram (`update`), two for the second (`get_or_insert`, `get`).
- `IntMap` now has power-of-two slots from a Fibonacci hash and a
  one-probe `add` (as StringMap's); NGram as Goose's, with `byteAt`.

### Words: 0.88 → 0.54 s (Goose/clang 0.55; 1.7× → 1.0×)

- Goose's dictionary is keyed by word slices of the text; the port made a
  String per word (`slice` of an FFI Buffer). Now the text is a String
  and the words count in a `SliceMap` (new one-probe `add`).

### LZWEncode: 0.72 → 0.67 s; Template::Parse tried, reverted

- `BytesMap` keeps each entry in its slot (`ByteSlot`, three I32s): a
  lookup reads one slot rather than a slot, then the entry's start and
  length elsewhere. LZWEncode 0.72 → 0.67 (Goose 0.51).
- Template::Parse as Goose's (byte lists, the name a trimmed range looked
  up with `findIn`, values appended with `appendRange`): 1.10 s, no better
  than the String version (1.0–1.1; Goose 0.67). The time is the slot
  load missing cache in a 6 MB table (3×50000 keys); reverted. Copying
  `this.textBytes` into a local cost a whole-list copy per step (lists
  are values): read fields in place.

### Binarytrees::Arena (1.5–1.8×): open

- Same structure and node layout (three 32-bit values). Same page
  faults and system time; user time 0.73 vs 0.49 s, all in `build`
  (`sum` is even). Goose/clang's `build` handles depth 1 in place, both
  leaf children written with no call (half of all nodes), and pushes
  through a cursor; ours calls itself for every leaf. A codegen matter
  (recursion peeling); left.

### Sort::Merge (1.56×), Maze::Generator (1.35×): looked at, open

- Sort::Merge: Goose copies the range into temp with one `copy_into`
  and merges until a side runs out, then copies the left rest only.
  Goose/gcc is 1.63 s, near ours (1.77); clang's 1.13 likely comes from a
  branchless pick. Ours: nested branches whose arms read different
  checked indices. Would want a range-copy intrinsic and if-conversion
  across checked reads; left.
- Maze::Generator: same structure (neighbours as 32-bit indices, Goose's
  as compressed 32-bit references); `adjacentOpen` compiles to a tight
  unrolled count. Bound by the scattered cell loads; left.

## Re-measure (step 21, `results/step21-goose.json`)

Zane / Goose-clang 1.14 geomean (step 19: 1.31), faster on 17; Zane /
Goose-gcc 0.91 (1.08), faster on 28. Worst vs clang: LZWDecode 2.8,
LogParser 2.5, SHA256 2.3, HuffDecode 2.1, BWTEncode 1.9,
Binarytrees::Arena 1.8, Template::Parse 1.8, CSV 1.7, Ast 1.6,
GameOfLife 1.55, Sort::Merge 1.5. Single-test runs are noisy at ±10%.

## Decisions from the user (2026-11-15)

- No unbounded `while`: bounded loops are what lets Zane evaluate
  aggressively at compile time, and `guard` already breaks out of a
  loop. The port's `i!to(bound)` loops with an early exit are the
  intended shape; a loop's exit belongs in `guard`, not a new construct.
- No regex library or comparator sort in core yet (LogParser, BWTEncode
  stay as they are).
- The compiler work goes to a PR.

## Compiler PR

Opened zane-lang/compiler#378 (branch `perf/list-ranges-float-reads`) on 2026-11-15 with the compiler side of this work.

# Second run (2026-11-15, branch `experiment/zane-vs-goose`)

The user lifted two limits for this run: a regex library (LogParser) and a
comparator/key sort in core (BWTEncode) are allowed. Goal: Zane about as
fast as Goose, or faster, on every test.

## Setup

- Compiler: `/home/user/compiler`, branch `experiment/zane-vs-goose` off
  v0.37 (f67247f, which has compiler#378). Core: `/home/user/core`, the same
  branch name, off v0.11 (bfdcb3c). LangArena: branch
  `experiment/zane-vs-goose` off `zane`.
- Toolchain: release v0.37 (`build.sh` now copies v0.37 to `dev`), compiler
  built with `pixi run just build`; the same `SW` switches as the previous run.
- Goose: `aardappel/goose` at 369c7a2 (the arena's pin), built with cmake as
  `docker/goose_clang`; benchmark `goose -O2 --standalone`, then clang 18.1.3
  / gcc 13.3 `-O2` (Ubuntu 24.04 compilers, a different machine from the
  first run).
- Report: `rep.py STEP.json` prints the table, worst ratio first.

## Baseline (step 22, `results/step22-goose.json`, `results/step22-goose.md`)

Zane (v0.37 + switches) / Goose-clang 1.106 geomean, faster on 16; Zane /
Goose-gcc 0.950, faster on 23. Worst vs clang: LZWDecode 3.1, LogParser 3.0,
HuffDecode 2.2, SHA256 1.8, BWTEncode 1.8, CSV 1.7, Template::Parse 1.6,
Binarytrees::Arena 1.5, Sort::Merge 1.4, Template::Regex 1.4, GameOfLife
1.35, NeuralNet 1.3, LZWEncode 1.3, ArithEncode 1.3, Binarytrees::Obj 1.3,
Ast 1.3.

Note on building: `zanec` embeds the runtime's C when it is built, so a
runtime change needs `pixi run just build` before `build.sh`; and `zane
build` keeps its own cache in `zane/out`, which does not see a new compiler
or runtime, so `build.sh` now empties `out/` whenever either changed. The
port's `zane.coda` points at the local core (`core v0.11 /home/user/core`).
New switch this run: `ZANE_ARM_CHECKS=1` (below); `SW` plus it is the build.

### BWTEncode: 0.84 → 0.39–0.48 s (Goose/clang 0.47)

- Goose sorts the suffix array each round with std `stable_sort`, a
  natural merge sort with a comparator over (rank, next rank) pairs. Ours
  ran two counting sorts per round, as C.
- Compiler + core: `List<I32>.sortBy(keys List<Int>)`: the indices sorted
  stably by the 64-bit key each names (runtime `zane_list_sort_by`), a
  natural merge sort as Goose's: runs found first (descending ones
  reversed, short ones made 16 by insertion), merges that copy a pair of
  runs already in order, a branchless pick while the merges alternate
  sides often and a branch otherwise. Port: one key per suffix,
  `rank*2^32 + next rank`, one `sortBy` per round, new ranks from equal
  keys.
- Of 17 rounds only 3 merge anything (runs 2842, 2276, 1139 of 100000);
  the other 14 find one run. A first version sorted (key, value) pairs,
  16 bytes moved per element per pass: 0.73–0.78 s. Indices with the key
  looked up (Goose's layout): the same, as the branchless merge waits on
  two dependent loads per pick; with Goose's switch to a branch when the
  merge alternates rarely: 0.39–0.48.

### Sort::Merge: 1.96 → 1.50 s (Goose/clang 1.35)

- Port as Goose's: the range copied to temp in one copy (new
  `List.copyRange(at, from, start, count)`, runtime `zane_list_copy`, a
  memmove), merged while both halves have elements, the left half's rest
  copied back. A `guard` in a `to` body ends that iteration only, so the
  loop runs on, doing nothing, to its count; the merge is a function of
  its own whose loop `return`s.
- That alone: 2.0–2.2 s. The pick stayed a branch: each arm checks `k`
  against `work`'s count before its store, so LLVM cannot sink the two
  stores into one store of a select.
- Compiler `Arm_checks` (`ZANE_ARM_CHECKS=1`, post-pipeline, as
  `Merged_checks`): where both arms of a branch only check the same index
  against the same bound, the check goes above the branch; then, in a
  diamond whose arms each store to the same address with only arithmetic
  after, the stores move to the arms' ends, so SimplifyCFG sinks them into
  one store and the arms become selects. Also fires in huffman decode,
  distance and yyjson. 1.50 s.

### SHA256: 0.90 → 0.45 s (Goose/clang 0.40)

- Goose's compiler strip-mines `for byte, i in data` indexed `i % 8` into
  runs of 8 whose index is the run's own counter ("loop shape:
  strip-mined by 8" in its C), so clang keeps the eight hashes in vector
  registers (SLP). Ours: LLVM unrolls by 4 from wherever IRCE's split left
  the loop, the index is never constant, the hashes stay in memory.
- Compiler `Strip` (CGT, `lib/optimize/strip.ml`, `ZANE_STRIP=1`): a
  counted loop whose body ends `x = x + 1`, indexes an array of 2–16
  (power of two) elements, uses `bitAnd`, and has no call, loop or scope,
  becomes `repeat c/N { x = start + b*N; N copies of the body }` and a
  remainder loop; each copy's locals and labels are renamed. With `start`
  known, each copy's `bitAnd(x-1+k, N-1)` folds and SROA puts the eight
  hashes in registers: 0.90 s, unchanged, as the copies' bounds checks of
  `data[x+k]` cut the block in eight and nothing vectorizes.
- The loop passes turn those checks into exit tests `b == (n+k) >> 3`
  against a loop that leaves at `b+1 == n >> 3`, which can never hold;
  LLVM does not see it. Compiler `Range_checks` (`ZANE_RANGE_CHECKS=1`,
  post-pipeline): such a test of a counter that starts at 0, steps by one
  and leaves at `(n+j) >> s`, against `(n+k) >> s` with k >= j, made false;
  also, a straight run of checks of `x+k` against one bound made one check
  of the lowest and highest offsets. Then `slp-vectorizer` again: 0.45 s.

### LZWDecode: 0.50 → 0.21–0.24 s (Goose/clang 0.18–0.21)

- The timed part is all user time, about 76% of it in libc's memcpy. A
  memcpy/memmove interposer (per call site, bytes and calls) shows that
  each decode copies about 5.2 MB, against Goose's 1.3 MB:
  - the appends (`appendOwn`, `appendRange`): 2 × 1 MB, the same as
    Goose's;
  - `zane_list_grow`: about 2.2 MB in 52 calls, as `strings`, `starts`,
    `lengths` and `out`, interleaved in one region, double through heap
    blocks to 1 MiB. Goose grows through `realloc`, which for blocks past
    128 KiB moves pages (mremap), not bytes;
  - one 1 MB copy per step, in the list type's move walk (ICF-folded into
    `brainfuck$Tape.move`): `this.decoded = decode(...)` moves the result
    from the call's region into `State`'s, by allocating there, copying
    and freeing the old block.
- Compiler `ZANE_REHOME=1` (`walks.ml`, runtime `zane_relocate`): a moved
  list's or string's block that is a growable span in the same context is
  handed over: its mapping leaves the old region's list for the new region's
  and its chunks are re-entered in the chunk map, with no byte copied.
  Alone, that was 0.51 → 1.3 s: the old `decoded`, freed on the next
  overwrite, went to `State`'s region stack, so every decode mapped fresh
  pages (478k minor faults). A handed-over span is flagged, and
  `zane_free` gives a flagged span to its context's kept spans instead,
  where the next list past 1 MiB takes it resident: 0.35 s.
- Compiler `ZANE_LIST_SPANS=N` (runtime `zane_list_span_from`, a weak
  global that zanec defines): a list whose block grows past N bytes has its
  room doubled past 1 MiB at once and takes a growable span, from where it
  grows in place. The runtime's rule that a list block past
  `ZANE_CHUNK - ZANE_LINE` is the one block of its span still holds, so
  nothing else changes; a list from 128 KiB to 1 MiB uses more address
  space, but only its touched pages use RAM. With N = 131072: 0.21–0.24 s.

## Re-measure (step 23, `results/step23-goose.json`, `results/step23-goose.md`)

All switches so far, `ZANE_REHOME=1` and `ZANE_LIST_SPANS=131072` included,
against the step-22 binary (`old` in the JSON) and Goose, three interleaved
rounds, minimum of each:

- Zane / Goose-clang geomean 1.087 (faster on 12), Zane / Goose-gcc 0.940
  (faster on 23); the step-22 binary in the same run: 1.107 and 0.958.
- Zane against the step-22 binary: geomean 0.98; LZWDecode 0.46. The
  largest slowdowns in the table (Words 1.15, TextRaytracer 1.13,
  Maze::BFS 1.12) do not reproduce in interleaved reruns, except
  TextRaytracer by about 3%.
- Worst left: LogParser 2.26, HuffDecode 2.12, CSV::Parse 1.74,
  Calculator::Ast 1.52, Template::Parse 1.48, NeuralNet 1.43,
  Spectralnorm 1.40, TextRaytracer 1.39, Binarytrees::Arena 1.38,
  Maze::Generator 1.34, Template::Regex 1.33, LZWDecode 1.30.

### LogParser: 0.57 → 0.46 s, a regex library in Zane (Goose/clang 0.25–0.27)

- The port used PCRE2's JIT through C. As the user allowed, it now has a
  regex library of its own written in Zane (`zane/lib/arena/rx.zn`, tests
  in `zane/test/rx`), on the model of Goose's `stdlib/regex.goose`:
  parsed to a syntax tree, compiled back to front to a Thompson NFA, and
  from it, by subset construction, a forward DFA with an unanchored
  `.*?` ahead of the pattern (leftmost-first: a thread's list stops at
  the first match) and a reverse DFA for where a match starts; byte
  classes; states renumbered dead, match states, then the start state, so
  one compare finds every state the loop must look at. Where the forward
  DFA is back in its start state, a skip: the prefix test (the two
  offsets whose byte sets are rarest by a rough frequency, as Goose's
  `choose_filter`) or the inner byte (a rare byte every match holds after
  a part that never consumes it, walked back from by the part's reverse
  DFA), chosen as Goose chooses.
- The scans are runtime intrinsics, Goose's `gs_scan_pair` and
  `gs_scan_any`: `String:findPair` and `String:findAny` (compiler
  `Text_find_pair`, `Text_find_any`, runtime/block.c), 16 positions at a
  time by SSSE3 shuffles over two 16-byte tables per set, exact for every
  set, a set's tables prepared once on the Zane side.
- Scalar skip loop: 1.21 s; with `findPair`: 0.67 s; with the inner byte
  as well: 0.46 s (PCRE2: 0.62 s).
- The patterns are the patterns PCRE2 had; checksums are unchanged.
  (Note: `guard(c)` leaves when `c` holds.)

### Template::Regex, Template::Parse: Goose's data layout

- Template::Regex on the new library is slower than with PCRE2 (2.3–2.5
  against 2.0–2.2 s): PCRE2 finds `{{` by memchr, and our reverse DFA
  walks back from each `}}` to where a match can start. The pattern is
  now Goose's, `[{][{](.*?)[}][}]`, whose `.` stops the walk at a newline.
- Both spent about 40–50% in `StringMap.slot` and much of the rest in
  per-byte FFI calls to the C `Buffer`. As in Goose's port, the text is now
  a `List<U8>`, the keys ranges of one byte list in a `BytesMap`, the
  values ranges of another, and a key is looked up by the text's own bytes
  (no `slice`/`trim` string per placeholder); runs of plain text are
  copied with `appendRange`. Template::Parse 1.47 → 1.44 s (Goose 0.95–
  1.13): the time is now in `BytesMap.slotIn`, about 90 ns a lookup, a
  cache miss into a 6 MB table, as Goose's 10 MB one also has.
- `BytesMap.slotIn` tested `length == count and sameRange(...)`: Zane's
  `and` evaluates both sides, so every probed slot compared bytes. Now
  nested.
- `StringMap` hashes with the runtime's word-at-a-time hash (`hashBytes`,
  the hash `hashRange` uses) instead of djb2 per byte.

### HuffDecode: looked at, left at about 2× (Goose/clang 0.69–0.81 s)

- The node is now Goose's (narrow fields and an `is_leaf` flag, 14 bytes
  packed); no change in time. Per bit our chain is `dec`, `shl`, `add` and
  the child's load (an index becomes an address); Goose's and C's are
  pointer chases, a load each. Padding the node to 16 bytes (a shift for
  the stride) did not change it either. A flat child table (`kids[2c+bit]`,
  leaf as a negative entry) would match a pointer chase, but it is neither
  Goose's nor C's design, so it is left out.

### CSV::Parse: 0.99–1.08 → 0.73–0.79 s (Goose/clang 0.53–0.56)

- The field loop is Goose's `csv::each_record` shape (a quoted field ends
  at its closing quote, any other at the first separator, line break or
  quote), each end found by `findAny` rather than a test of every byte.
- `zane_parse_f64` (0.68 s of samples to Goose's `parse_flt` 0.45) is the
  same algorithm as Goose's (digits folded, one division by an exact power
  of ten); its code is as tight; left.

### Calculator::Ast: 0.21–0.23 → 0.17 s (Goose/clang 0.15–0.21)

- Compiler `ZANE_IDLE_SEARCH=1` (`Loop_shapes.idle_counter`): a loop that
  can leave early, holds no loop, and whose counter nothing in its body
  reads but its own step (a `to` that stands for a `while`) is weighted
  as a search (4 trips), as `searches` weights a scan, so IRCE leaves it
  whole. `whitespace`'s position is a field `advance()` moves, which
  `scans` cannot see.

## Re-measure (step 24, `results/step24-goose.json`, `results/step24-goose.md`)

Everything through `ZANE_IDLE_SEARCH`, against the step-23 binary (`old`):

- Zane / Goose-clang geomean 1.073 (faster on 16), Zane / Goose-gcc
  0.930 (faster on 27); the step-23 binary in the same run: 1.076, 0.933
  (this run was quieter than step 23's).
- Against the step-23 binary: LogParser 0.75, CSV::Parse 0.77,
  Calculator::Ast 0.78, Binarytrees::Obj 0.83. The slower rows
  (CacheSimulation 1.28, Template::Regex 1.13, HuffDecode 1.12,
  Maze::Generator 1.11) swing as much between reruns of one binary
  (CacheSimulation 0.95–1.48 s), and reruns show no consistent change.
- Worst left: HuffDecode 2.28, Binarytrees::Arena 1.66, LogParser 1.63,
  Template::Parse 1.50, Maze::Generator 1.49, Template::Regex 1.43,
  ArithEncode 1.38, GameOfLife 1.37, LZWEncode 1.35, CSV::Parse 1.32.

## Spectralnorm, NeuralNet, recursion peeling (after step 24)

- Spectralnorm: `element` now computes `Float(i+j)` once, as Goose's
  `eval_a` does: 1.44 → 1.11 s (Goose 1.07).
- NeuralNet: neurons now hold their synapses as Goose's do, in inline
  `Array<I32,10>` arrays named by 32-bit indices. Measured neutral (1.39
  against 1.33 with the old lists, inside the noise), kept since it is
  Goose's layout. The gap to Goose (≈1.36 vs 0.97 s) is in instructions,
  not latency: callgrind counts 25.4 G against 18.5 G. Both spend the same
  4.76 G in libm `exp` (the same 89.76 M calls, 4.9 ns each in either
  process, the same MXCSR). The rest is the hop through each
  synapse: Goose's `Neuron&<u32>` is an unchecked self-relative offset
  (`movslq; add`), ours a checked 1-based index (`movslq; dec; cmp; jae;
  shl`). Two hops per synapse visit, ~90 visits per `train`, account for
  about two thirds of the 6.9 G gap. That price is the checked index
  itself; left.
- `ZANE_PEEL_RECURSION=1` (new, `lib/optimize/recursion_peel.ml`): gives
  each small self-recursive function an always-inlined copy `f$peel` that
  its self-calls go to, so one level of recursion is inlined. Not useful:
  Binarytrees::Arena 0.584 → 0.608, Sort::Quick 1.636 → 1.736. Off.

### GameOfLife: 0.90 → 0.80 s (Goose/clang 0.69)

Cells now laid out as Goose's: inline in one `List<Cell>` (was a
`ListRef` of boxed cells, each with its own `List<Int>` of neighbours),
the eight neighbours as `Array<I32,8>`. The step loop is fully unrolled;
what is left per neighbour is the checked index (`movslq; dec; cmp; jae`)
and the ×34 element scaling (`mov; shl; lea`), against Goose's unchecked
byte offset.

### Frame shadow miscompile found and fixed

Building with `ZANE_LLVM_OPTS=-inline-threshold=400` (new: extra LLVM
options) made BWTDecode fail its checksum. Bisected to `ZANE_FRAME_SHADOW`,
in `bwt$encode`, slots 288/296: the `ranks` list. `ranks=nextRanks` calls
`List<I32>.overwrite(slot, …, jobs)`, which keeps the slot's address in a
deferred job, and the inlined job loop after it runs the job by an
indirect call given only what it loaded from the job list. The pass
filled its copies again only after calls given a frame address, so the
round loop read a stale `ranks`. Now a frame address given to a
parameter not marked `captures(none)` makes the frame escaped, and the
copies are filled after every later call. The default build was right
only by luck of inlining. New bisecting switches: `ZANE_FRAME_SHADOW_ONLY`
(function name), `ZANE_FRAME_SHADOW_SLOTS`, `ZANE_SHADOW_AGAIN`,
`ZANE_DUMP_BEFORE`/`ZANE_DUMP_AFTER=<experiment>=<path>`.

### ArithEncode (1.52 s, Goose/clang 1.10)

- `BitWriter` now writes into a `List<U8>`, as Goose's bit stream does
  (was the FFI `Buffer`): 1.52 → 1.45.
- Left: Goose's compiler divides by `total`, which the loop never changes,
  through a libdivide-style reciprocal made before the loop (no `div` in
  its loop); ours does two 64-bit `idiv` per symbol. Our divisor is also
  reloaded from the frame after every `emit` call, which LLVM does not
  inline (inlining it at threshold 400 gains nothing).
- `ZANE_DIV_CACHE=1` (new, `lib/codegen/div_cache_stubs.cpp`): each
  64-bit signed division or remainder in a loop by a non-constant divisor
  keeps the divisor it last saw and its libdivide multiplier and shift
  (`zane_div_magic` in runtime/block.c, Goose's `gs_divu_gen` algorithm)
  in allocas that SROA makes loop registers. A new divisor computes them
  again; 0, 1 and -1 divide the plain way. The quotient of |x| by |d| is
  libdivide's unsigned one, signed as x·d. Checked against 20 M random
  pairs (both signs, the extremes, powers of two). Caching by value, not
  proving the divisor loop-invariant, because ArithEncode's `total` is
  reloaded from the frame after each `emit` call. ArithEncode 1.67 → 1.47
  (Goose/clang 1.03). Its risk is a loop whose divisor changes every
  time; step 25 measures the whole suite with it.

## Re-measure (step 25, `results/step25-goose.json`, `results/step25-goose.md`)

Everything through `ZANE_DIV_CACHE` (first form) plus the GameOfLife,
BitWriter, Spectralnorm and NeuralNet port changes, against the step-24
binary (`old`) in the same run: Zane / Goose-clang 1.064 (faster on 17),
Zane / Goose-gcc 0.910 (faster on 29); `old` 1.055 / 0.903. No net gain:

- Reruns pin two losses on the first `ZANE_DIV_CACHE`: ArithDecode
  1.26 → 1.61 (its divisor `range` changes every symbol, so every
  division made a new reciprocal) and Calculator::Interpreter (noise:
  0.534 / 0.533 over nine rounds). The others in the worse list
  (Words, NeuralNet, CacheSimulation, Base64) do not reproduce.
- Fixed: a new divisor is now only noted and divides the plain way; its
  reciprocal is made the second time it comes. ArithDecode 1.17 / 1.16
  with and without; ArithEncode 1.45 → 1.38.
- Worst left vs clang: HuffDecode 2.17, LogParser 1.66, LZWDecode 1.51,
  Template::Parse 1.50, Template::Regex 1.48, LZWEncode 1.43,
  ArithDecode 1.43, NeuralNet 1.38, TextRaytracer 1.37,
  Binarytrees::Arena 1.33.

### TextRaytracer: 1.08 → 0.83 s (Goose/clang 0.79–0.93)

- Scene as Goose's constant `SCENE`: a local `Array<Sphere,3>` literal
  (was a `List` in the state): 1.08 → 1.05.
- Lookup table as Goose's `const LUT: u8[6]`: an `Array<U8,6>` with
  Goose's fallback to a space (was a `String` local, whose frame was
  placed and torn down, 224 bytes zeroed, for every hit pixel): → 0.93.
- `ZANE_CONST_ARRAYS=1` (new, `lib/codegen/const_arrays.ml`): an alloca
  whose every write is a constant store at a constant offset (the same
  bytes each time) and that is otherwise only loaded or copied from
  becomes a private constant global, as clang makes Goose's `const`
  arrays. The scene was rebuilt on the stack for every pixel, since the
  hit sphere is read by an index LLVM does not know: → 0.83.

### LZWDecode: 0.21 → 0.166 s (Goose/clang 0.16)

Same algorithm as Goose's (entries as ranges of one byte list, appended
to it and to the output). The extra was `zane_list_grow`: 1.26 GB copied
in 92 k reallocations as `strings` and `out` doubled up to the 128 KiB
growable-span threshold. `ZANE_LIST_SPANS=16384` (from 131072): LZWDecode
0.21 → 0.166; 32 KiB 0.174, 64 KiB 0.186. LZWEncode, HuffEncode,
Json::Generate and Words move ±10% between reruns at every threshold,
with no order. Builds from here use 16384.

### LogParser: ~0.40 → ~0.34 s (Goose/clang 0.24–0.25)

callgrind: the DFA (`findEnd`) costs as Goose's (2.06 G against 1.74 G
instructions), and both make the same 5.94 M pair searches, but ours
cost 450 instructions each against Goose's 263. Now as Goose's
`gs_scan_pair`:
- `rxTable` classifies each set after its tables (bytes 289–293): one to
  three bytes, or three non-members complemented, or a run, or tables
  (Goose's byte-set classes); the runtime instantiates the block loop for
  each pair of classes and tests small sets with `pcmpeqb`.
- The table test takes pshufb's zero for an index with its top bit set
  (`lo[x]`, `hi[x ^ 0x80]`) instead of masking each half: 0.40 → 0.33.
- The last partial block is one overlapping load, its searched
  positions shifted out of the mask, not a byte loop: → ~0.34 (the
  machine swings ±10% today).

### Template::Regex and Template::Parse now ahead of Goose

- The key trim in `substitute` walked every byte of every key twice,
  since `and` evaluates both sides and the loop never left early; now
  `firstNonSpace`/`lastNonSpace` return at the first non-space, as
  Goose's `trim` stops: Regex 2.12 → 1.37 (Goose 1.54), Parse 1.34 →
  0.92 (Goose 0.94). callgrind had `substitute` at 4.16 G instructions.
- Tried and reverted: a hash tag in each `BytesMap` slot as Goose's
  dictionary keeps (16-byte slots: LZWEncode 0.76 → 0.90, Regex
  worse), and `Rx.classes` as a fixed `Array<I32,256>` (the byte's class
  check goes, but the 1 KiB array is copied with the `Rx` into
  `matches`: Regex 1.98 → 2.35).

### `ZANE_LITERAL_LOCALS`: a local string literal places no frame

`lut String=String(".-+*XM")` is a `String`, a type that can own a
block, so lowering holds it in its scope's arena, and the function
places, zeroes, links and drains a 256-byte frame on every call, though
the fold finds the value is constant bytes and its reads already read
the constant. The new pass (compiler `lib/optimize/literal_locals.ml`,
after the fold) binds such a `Hold` by a plain `Let` when the local is
never assigned, moved or lent by address, and drops the scope it leaves
empty when nothing else is held there and nothing in it can need the
arena for a fresh owner given to a callee: its calls are runtime reads
(`zane_array_at`, ...) or functions given no value that can hold a
handle or an address.

- Repro (a `pick` with a local LUT called 1e8 times): 0.56 → 0.02 s; the
  loop vectorises once the frame is gone.
- TextRaytracer is back to the plain `String` LUT (`lut:byteAt`) instead
  of the hand-written `Array<U8,6>`: 0.99 s without the switch, 0.83 with
  it, the `Array` port 0.82, Goose/clang 0.85 (9 interleaved rounds).
- 50/50 checks pass. No other benchmark has a local literal that
  qualifies (codec's `pattern` scope also holds a buffer; csvbench's
  `truth` is assigned).

## Re-measure (step 26, `results/step26-goose.json`, `results/step26-goose.md`)

Every switch so far plus `ZANE_LITERAL_LOCALS=1`, 3 interleaved rounds
against Goose's clang and gcc builds.

- Geomean Zane / Goose-clang 1.025 (step 25: 1.064), faster on 20 of 50;
  Zane / Goose-gcc 0.865, faster on 32.
- Worst left vs clang: HuffDecode 2.21, Binarytrees::Arena 1.51,
  LogParser 1.50, ArithEncode 1.38, Graph::BFS 1.32, NeuralNet 1.29,
  LZWEncode 1.23, Maze::Generator 1.22, GameOfLife 1.21.
- Template::Regex and Template::Parse are ahead now, and
  TextRaytracer/LZWDecode are within noise.

### Binarytrees::Arena and HuffDecode after step 26: looked at, left

- Arena: same page faults and memory as Goose (6.3 k minor faults, 27 MB);
  the gap is `build`. `ZANE_PEEL_RECURSION=1` now gives Goose's shape
  (depth-1 children written in place, no call), and one run had Arena
  0.556 → 0.506, but a 3-round run of all 50 tests against step 26 is a
  wash (geomean 0.998) and 5 interleaved rounds of the extremes are all
  within noise, Arena included (0.565 vs 0.598). Left off.
- HuffDecode (2.2×): latency-bound on the per-bit chain `dec` (1-based
  index), stride ×14 (`lea`/`shl`/`sub`), base add, load: about 9
  cycles against Goose's single pointer load. Taking the `dec` off the
  chain is the biased-base idea, which is not being pursued; the 16-byte
  stride was tried before. Left.

### Graph::BFS (1.2–1.3×): looked at, left

- Same algorithm and the same inner loop as Goose's, but for our `dec`
  of the 1-based neighbor index and a capacity check on each queue push
  (Goose's queue grows in a reserved span and pushes through a cursor).
  Half the samples are on the load of each adjacency list's first item.
- Goose puts every adjacency slice in one pool (`edges.realloc_slice`);
  ours are separate lists grown by doubling (RSS 87 MB vs 66 MB). A
  diagnostic copy of every list into fresh, packed lists in vertex order
  after `prepare` gave only 1.614 → 1.572 (Goose 1.341), so placement is
  not the cause. Reverted.

### `ZANE_BIASED_BASE`: the 1-based index's `- 1` off the address chain

The element address was `base + (index - 1) * stride`, and the `index - 1`
is shared with the bounds check, so a loaded index (a tree's child, a
graph's neighbor) went through a `dec` before it was scaled. With
`ZANE_BIASED_BASE=1` (compiler `lib/codegen/emit.ml`, `element`) the
address is `(base - stride) + index * stride`: the biased base is loop-
invariant and the check keeps its own `index - 1`. 50/50 checks pass.

- HuffDecode 1.486 → 1.368 (Goose/clang 0.69); Graph::BFS 1.595 →
  1.578 and Binarytrees::Arena 0.484 → 0.543, both within noise
  (5 interleaved rounds).
- With the bias, HuffDecode's 14-byte node padded to 16 bytes (two
  spare `U8` members, so the stride is a shift): 1.367 → 0.949. Without
  the bias the same padding measured no gain earlier (step 23-24); the
  re-check of that is still to run. The padded node is in the port for
  now.

#### `ZANE_BIASED_BASE` measured (medians of interleaved runs)

The machine swings ±25% between batches today, so these are medians of
7–12 interleaved runs, not minimums.

- HuffDecode (12 runs): step 26 1.497, 16-byte node only 1.450, biased
  base only 1.371, both 1.236 (−17%). Both stay.
- All 50, 3 rounds (`results/biased-base.json`): geomean 1.006 against step 26,
  inside the noise. The extremes, again by medians of 7:
  Brainfuck::Recursion 2.242 → 1.981, NeuralNet 1.474 → 1.307, Words
  0.710 → 0.633; Sort::Self 0.415 → 0.406 and Template::Regex 1.538 →
  1.584 the same; Brainfuck::Array 1.739 → 2.001. Its loop is the same
  instructions both ways (the cell's `- 1` is a displacement now, as
  `incb -0x1(%r12,%r9,1)`), an indirect-jump dispatch whose time moves
  with code placement, so that is layout, not the bias.
- On from here (builds use `ZANE_BIASED_BASE=1`).

### HuffDecode: 1.50 → 0.81 s (Goose/clang 0.74, medians of 9)

- Every whole byte's bits in a `b!to(Int(8))` loop, the last byte's
  after, as Goose's `for j in 8`: 1.229 → 1.179 alone, since LLVM keeps
  the loop (a body with the leaf branch is over its unroll threshold).
- `-unroll-threshold=1000` for the whole build: 1.188 → 0.845. So the
  compiler now asks for it where Goose's does: `ZANE_UNROLL_SMALL=8`
  (compiler `lib/codegen/emit.ml`, the `to` loop) puts
  `llvm.loop.unroll.full` on a loop whose count is a constant from 2 to
  8, as C's `#pragma unroll`: 0.807 (Goose 0.737). 50/50 checks pass.
- With `ZANE_BIASED_BASE` and the 16-byte node, step 26's 1.497 is now
  0.807: 2.2× → 1.1×.
- All 50, 3 rounds (`results/unroll-small.json`, medians): geomean 0.996
  against the same build without it; HuffDecode 0.80×, Json::Generate,
  Maze::Generator and TextRaytracer 0.82–0.88×. The worst, by medians of
  9 more: Base64::Decode 0.149 vs 0.150, CacheSimulation 1.104 vs 1.107,
  Json::Generate 0.240 vs 0.245 (all the same); Graph::AStar 1.140 vs
  1.228 by median with the same minimum (1.123 vs 1.120). On from here.

## Re-measure (step 27, `results/step27-goose.json`, `results/step27-goose.md`)

Step 26's switches plus `ZANE_BIASED_BASE=1` and `ZANE_UNROLL_SMALL=8`,
HuffDecode's 16-byte node and whole-byte loop; 3 interleaved rounds.

- Geomean Zane / Goose-clang 0.982 (step 26: 1.025): Zane is now ahead
  of Goose's clang build overall, faster on 23 of 50. Zane / Goose-gcc
  0.854, faster on 28.
- HuffDecode is off the top of the list.
- Worst left vs clang: LogParser 1.50, Maze::Generator 1.39,
  Binarytrees::Arena 1.38, ArithEncode 1.38, LZWEncode 1.38, LZWDecode
  1.30, Binarytrees::Obj 1.29.

### Maze::Generator (1.25× by medians): `ZANE_LOOP_INLINE`, `ZANE_ELEM_TBAA`

Session of 2026-11-15. Medians of 7–9 interleaved runs from here on
(`med.sh`-style: pinned to CPU 2, binaries alternated each round).

- Start: Zane 0.622, Goose/clang 0.501, Goose/gcc 0.570. Huge pages are
  on for the 47 MB cell list and help (0.575 vs 0.651 with `ZANE_HUGE=0`);
  Goose's malloc gets none (THP is `madvise`).
- callgrind (3 iterations, `--cache-sim --branch-sim`): Zane has *fewer*
  D1 misses (6.8 M vs 8.2 M) and mispredicts (7.8 M vs 7.1 M about the
  same) in the timed code, but 914 M instructions against Goose's 654 M.
  The DFS is bound on the miss of each neighbor's `kind`; a fatter loop
  body keeps fewer of those misses in flight.
- `adjacentOpen` stayed a call in `dig` (LLVM: cost 480, threshold 225;
  the loop over `degree` unrolled to four checked index loads). Goose's
  `count(...) { ... }` is inline by construction.
  `ZANE_LLVM_OPTS=-inline-threshold=600` gave 0.622 → 0.563, but on all 50
  (3 rounds) it is a wash with big swings: Graph::BFS 1.52 → 1.75,
  GameOfLife 0.70 → 0.85, Json::ParseDom 0.13 → 0.10, Brainfuck::Array
  2.22 → 1.81 (layout). Not taken.
- `ZANE_LOOP_INLINE=N` (new, compiler `lib/codegen/loop_inline.ml`): after
  LLVM's passes, a call in a cycle of its caller's blocks to a function of
  the program that is a loop-free leaf (only noreturn functions and
  intrinsics called) of at most N instructions is marked `alwaysinline`,
  then always-inline and a cleanup run again. A first version judged
  callees before the passes: it also inlined SliceMap's byte-compare loop
  `same` into its probe loop (Words 0.570 → 0.638, +12%) and the bundled
  C, so it now looks at the optimized callee and skips any with a loop.
  With N=128 it takes `adjacentOpen` (112 instructions), CacheSimulation's
  `front` (74) and two regex-setup helpers, nothing else.
  Maze::Generator 0.578 → 0.531, CacheSimulation 1.087 → 1.046 (medians
  of 9). Goose/clang 0.437 in the same runs: 1.32× → 1.21×.
- `ZANE_ELEM_TBAA=1` (new, `lib/codegen/elem_tbaa.ml`): the stack's push
  stores an `i32` with the same sized TBAA tag as the cells' fields, so
  LLVM takes the push to have written the current cell. Each scalar access
  traced to a `List_at`/`List_push` address now gets a child of its sized
  tag for the list's stride, and a per-stride `!alias.scope`/`!noalias`;
  a runtime push call of stride s is `!noalias` every other stride's
  scope (lists of different strides never share a block, the same
  assumption as the handle/scalar split). It tags correctly but changes
  nothing here: the reloads after a push are of loads that were only
  partly available before it (behind `adjacentOpen`'s `degree` exits).
  All 50, 3 rounds: geomean 1.008, noise. Left off.
- What is left in Maze::Generator (1.2×): per neighbor, our checked
  1-based index (`movslq; lea -1; cmp; jae`) and the ×24 scaling
  (`lea (r,r,2)`, then the load) against Goose's self-relative 32-bit
  pointer (`movslq; movzbl (r,off)`), and a reset loop that branches per
  cell where Goose's is vectorized.

### LZWEncode: 0.835 → 0.753 s (Goose/clang 0.643, medians of 7)

- The encoder's `BytesMap` was sized for the worst case up front
  (min(2n + 1024, 131072) slots: 1.5 MB, zeroed every call) for the
  ~2.7 k keys one call holds (the test data repeats, so strings get long
  and few codes are made), so each probe missed the cache. Goose's
  dictionary reserves 4096 keys and doubles at 2/3 load. The port's
  `BytesMap` now grows the same way (`grow`, entries placed again) and LZW
  reserves 4096 keys: 0.835 → 0.755. Template and LogParser, its other
  users, are unchanged.
- The byte-range hash (runtime `zane_bytes_hash`) mixed each word with an
  xorshift (`mov; shr; xor`); Goose's rotates (`rol`). With the rotate
  written as shifts, clang made it a second multiply by the constant
  shifted, so it is `__builtin_rotateleft64` now, and the close is
  Goose's two multiply-xorshift rounds: the hash's instructions 65.6 M →
  50.0 M (3 iterations; Goose's 48.5 M); time 0.772 → 0.753, within the
  noise (the four lanes' multiply chains were the bound already).
- A port of Goose's whole hash (two lanes past 24 bytes, its short path
  out of line) was more instructions here (72 M, the wrapper no longer
  inlined): reverted.
- Left (1.13–1.17×): both spend about the same in the key compare (the
  first load of the stored key is a miss, ours glibc's AVX-512 `memcmp`,
  Goose's `gs_memeq_long`); our hash is about a third more samples than
  Goose's for the same instruction count.

## Re-measure (step 28, `results/step28-goose.json`, `results/step28-goose.md`)

Step 27's switches plus `ZANE_LOOP_INLINE=128`, the growing `BytesMap`
and the rotating hash; 3 interleaved rounds, minimums. A new container
(2026-11-15/16), so not the machine of step 27: Goose's own times moved
too (Binarytrees::Arena 0.395 → 0.330, Maze::Generator 0.435 → 0.431).

- Geomean Zane / Goose-clang 1.006 (faster on 20 of 50), Zane /
  Goose-gcc 0.856 (faster on 29).
- Worst vs clang: Binarytrees::Arena 1.80, LogParser 1.48, ArithEncode
  1.37, SHA256 1.30, Binarytrees::Obj 1.28, Brainfuck::Array 1.27,
  Fannkuchredux 1.22, NeuralNet 1.21, Graph::BFS 1.17.
- Maze::Generator is down to 1.09, LZWEncode 1.13.

### `ZANE_LEAF_PEEL`: Binarytrees::Arena 0.549 → 0.348 s, Obj 0.389 → 0.265 s

Medians of 7; Goose/clang 0.346 and 0.283 in the same runs, so Arena is
level with Goose and Obj ahead.

- Arena was 1.46× by medians: callgrind (3 iterations) had our `build`
  at 267 M instructions and 15.7 M branches against Goose's 186 M and
  9.4 M; same page faults (6.3 k) and memory (27 MB), all user time.
- Goose's compiler emits each self-call of `build_tree` as `if (depth - 1
  > 0) call; else <the leaf node written in place>`: the base case is made
  at the call, so the leaves (half of all nodes) take no call.
  `ZANE_PEEL_RECURSION` instead inlines a whole level of the body at each
  self-call (more code and spills): Arena 0.584 → 0.554, Obj 0.408 →
  0.343, but Sort::Quick 1.80 → 1.93.
- `ZANE_LEAF_PEEL=1` (new, compiler `lib/codegen/leaf_peel_stubs.cpp`):
  after LLVM's passes, a self-recursive function of the program (at most
  200 instructions) with a conditional branch on a compare of its
  arguments and constants, one side of which leaves no self-call
  reachable from the entry, is cloned as `F$leaf` with that branch fixed;
  each self-call then goes to `F$peel`, which makes the compare on the
  call's arguments and calls `F` or `F$leaf`. Both are always inlined and
  folded by the passes run again. Since arguments do not change, the
  compare at the call is the compare `F` would make.
- It takes both binarytrees `build`s, `sort$merge` and brainfuck's `Op`
  copy/end/move layouts. Sort::Merge 1.48 → 1.51 and Brainfuck::Recursion
  2.12 → 2.13 (within noise). 50/50 checks pass.

### Compress::ArithEncode: emit, the frame's refills, the divisor

Medians of 7: the step-28 build plus `ZANE_LEAF_PEEL` 1.60 s, Goose/clang
1.18 s (1.36×). Callgrind: 13.2 G instructions against Goose's 5.5 G, 72%
in `encode` and 24% in `emit`, which stays a call: it has a loop (the
pending bits) and calls the runtime's push, so `ZANE_LOOP_INLINE` leaves
it. Each call of it made `encode` load the table's lists and total, the
input and its bounds from the frame again (the frame's address escapes,
so a call may write any slot).

- `ZANE_LOOP_INLINE_LOOPS=M` (new): a callee with a loop of its own, of
  at most M instructions, is taken too, and with it a callee may call
  `zane_list_push`/`zane_list_reserve`. At 128: ArithEncode 1.60 → 1.47–1.51.
  It also takes NGram's `add`, Maze/Graph `push`, Mandelbrot's
  `inside.lookup`, regex `scanBack`, NeuralNet's `connect`.
- The reloads stayed, now once per byte written: `ZANE_FRAME_SHADOW`
  fills every shadowed slot again after any call given a frame address,
  and two such follow each byte: the `memset` instcombine makes of
  `pendingByte=0; bitPosition=0` and the push's growth path.
  `ZANE_SHADOW_REFILL=1` (new, `frame_shadow.ml`): after a constant-length
  `memset`/`memcpy`/`memmove` only the slots its destination covers are
  filled again, after a list growth call only its header's, whether or
  not the frame's address went elsewhere (the growth writes through no
  address it was given before).
- With the slots in registers `total` is loop-invariant, but the division
  still went through `ZANE_DIV_CACHE`'s per-division cache (compare with
  the last divisor, check the shift). `ZANE_DIV_HOIST=1` (new,
  `div_cache_stubs.cpp`): a divisor the outermost loop around it does not
  change gets its multiplier and shift once, in that loop's preheader
  (made when the passes left none), as Goose's compiler emits
  `gs_divu_gen` before the loop.
- All three: 1.52 s, 10.2 G instructions; Goose 1.18. Branch simulation
  has about the same mispredicts (217 M vs Goose's 203 M, the normalize
  loop's three tests); Goose peels its first pass. What is left per
  symbol: our division is signed (an absolute value and a sign fix each,
  Goose's is unsigned), the normalize loop's bound of 64, three index
  checks, spilled values, and the slot stores frame shadow keeps.

### Etc::LogParser: the byte sets' `zane_set_kind` byte was read one byte off

Sampled (step-28 build + `ZANE_SHADOW_REFILL`): 4.28 s whole run against
Goose's 3.08; `zane_pair_blocks` 1.79 s against Goose's `gs_find_pair` +
`gs_scan_pair_tables` 1.24 s, our `findEnd` 1.40 s against Goose's
1.56 s. Callgrind: the same 5.9 M pair scans and 2.4 M `findEnd`s, but
every one of ours went through the two-table test, where Goose's takes
the compare tests for 2.6 M of them. `rx.zn`'s `rxTable`/`rxKind` wrote
the set's `kind` byte, complement flag and bytes at its (1-based) 289, 290 and
291–293, which are bytes 288–292; the runtime reads them at 289–293
(`zane_set_kind`, `zane_bsm_init`). So it took the complement flag (0)
for the `kind` byte, and `kind` 0 falls to the default, the tables. Port fixed
(the indices one up). A complemented set would have read its first byte
as the flag; none of LogParser's or CSV's are, and 50/50 checks passed
before and after.

Medians of 7: LogParser 0.386 → 0.309 s (Goose 0.258, 1.20×),
Template::Regex 1.51 → 1.42 (Goose 1.49), CSV::Parse 0.639 → 0.613
(Goose 0.544).

### After the ArithEncode switches, all 50 (3 rounds, medians)

Against the step-28 build plus `ZANE_LEAF_PEEL`:

- `ZANE_SHADOW_REFILL` + `ZANE_DIV_HOIST`: geomean 1.005. Separately,
  medians of 7: `ZANE_SHADOW_REFILL` alone Brainfuck::Array 1.89 →
  1.70, the rest the same; `ZANE_DIV_HOIST` alone Brainfuck::Array 1.89
  → 2.20, Json::Generate 0.245 → 0.280, CSV::Parse +6%. Making the
  hoisted multiplier through the cache's protocol in the preheader (a
  compare per entry to the loop, the multiplier only on a divisor's
  second entry) left Json::Generate at 0.278, so the cost is the extra
  LICM/unswitch run over every function, not the multiplier; ArithEncode
  gains nothing from it. `ZANE_DIV_HOIST` stays off,
  `ZANE_SHADOW_REFILL` goes on.
- `ZANE_LOOP_INLINE_LOOPS=128` on top: ArithEncode −4%, NGram −7%,
  Binarytrees::Obj −8%, but Maze::AStar +7% (the heap's sift-up loop
  inlined into `step`) and CSV::Parse noisy. Off: a budget that takes
  `emit` but not the heap's push would be fitted to the benchmark.

## Re-measure (step 29, `results/step29-goose.json`, `results/step29-goose.md`)

Step 28's switches plus `ZANE_LEAF_PEEL=1` and `ZANE_SHADOW_REFILL=1`,
and the `rx` byte-set fix; 3 interleaved rounds, minimums, same container
as step 28.

- Geomean Zane / Goose-clang 0.984 (faster on 19 of 50), Zane /
  Goose-gcc 0.833 (faster on 34). Step 28: 1.006 and 0.856.
- Worst vs clang: ArithEncode 1.31, SHA256 1.29, LogParser 1.23, Sieve
  1.21, HuffDecode 1.20, Fannkuchredux 1.20, Maze::Generator 1.19,
  ArithDecode 1.18, NeuralNet 1.16, CSV::Parse 1.16.
- Binarytrees::Arena and Obj are no longer among them (LEAF_PEEL), nor
  Brainfuck::Array (SHADOW_REFILL).

### Hash::SHA256: half of the eight hashes vectorized

0.519 s against Goose/clang's 0.402 (step 29). Same algorithm: eight
32-bit hashes in an array indexed by `i % 8`. Both binaries' loops are
unrolled by 8, but Goose's keeps the eight in two SSE vectors (24
instructions per 8 bytes) and ours one vector and four scalars (45).
Goose's compiler strip-mines the loop itself (`/* loop shape:
strip-mined by 8 */` in its C: an inner `for t37 < 8` indexing the
array by `t37`), clang unrolls that inner loop whole and the SLP
vectorizer finds two groups of four stores in its body (`Stores SLP
vectorized with cost -8/-9`). Ours reaches the same shape only by LLVM's
runtime unroll by 8, late, after which SROA has made the array eight
scalars: the only stores left are the eight after the loop, and SLP
groups lanes 1–4 of them, leaving 0 and 5–7 scalar. `-slp-threshold=-6`
changes nothing. Open: a strip-mined loop shape in the compiler for an
array indexed by the loop counter modulo a small constant.

### CLBG::Fannkuchredux: the rotation's `memmove`

Medians of 7: 1.63 s against Goose/clang 1.35 (1.21×). Sampled: 88% in
`step` (`flip` and `advance` inlined), 9% in libc's `memmove`: the port's
rotation `perm1[i] = perm1[i + 1]` for i in 1..r is a copy loop, which
LLVM's loop idiom pass makes a `memmove` call, of r elements with r
mostly 1 or 2, once per permutation. Goose's port rotates by swaps,
which the idiom does not take.

`ZANE_NO_COPY_IDIOM=1` (new, compiler `passes.ml`): LLVM's
`-disable-loop-idiom-memcpy`, so element-copy loops stay loops. In this
program it changes `fannkuch$step` alone (the only function whose call
sites of `memmove`/`memcpy` differ). Fannkuchredux 1.63 → 1.43 s (Goose
1.35); 50/50 checks pass. On.

### Compress::ArithDecode: two tries, neither kept

Medians of 7 with `ZANE_NO_COPY_IDIOM`: 1.29 s against Goose/clang 1.13
(1.14×). Sampled: 97% in `step` (decode inlined); the most samples
(12%) just after the 64-bit `idiv` by `range`, which varies per symbol
and which Goose makes too (as `div`; on this Emerald Rapids core the two
cost about the same time). The rest is spread: the binary search, the bit
reader (`position/8`, a check and a byte load per bit), and the
decoder's fields (`low`, `high`, `value`, the reader's position) stored
to the frame each time round `normalize`.

- The bit reader as Goose's `BitInputStream` (the current byte kept, a
  bit position, the next byte read every 8 bits): 1.31 → 1.44 s, slower
  (one more field stored to the frame per bit, and a branch). Reverted.
- The stores: frame shadow keeps a slot's reads in registers but writes
  the frame at each store, and LLVM may not sink a store out of a loop
  into memory another thread could see (the frame's address is in the
  scope chain). Tried writing shadowed slots back only before calls and
  returns (`ZANE_SHADOW_LAZY`) for frames whose slot addresses go
  nowhere else; every one of the 73 shadowed frames in this program has
  such an address (a callee that may keep it), so it never applied.
  Doing it for those would take a write-back before each access that
  may alias a slot, which needs alias information this pass has not.
  Dropped, not committed.

### Matmul::T4/T8/T16: workers by columns, as Goose's

Step 29: T16 1.13×, T8 1.09×, T4 1.07×, Single 0.99×. The runs are
pinned to one CPU, and on it Goose's T16 (4.77 s) beats its own Single
(5.32): its workers each take a block of columns (`width` = n / threads)
for every row, so a worker reads only its rows of the transpose, a tile
that stays in cache across the 900 rows. The port split by rows, each
worker reading the whole transpose. Port changed to Goose's split
(`multiplyColumns`; the result's rows joined from the workers' blocks
with `appendRange`). Medians: T16 5.43 → 5.13 s (Goose 5.11), T8 5.50 →
5.23 (4.92), T4 5.51 → 5.66 (5.08; minimums 5.37 → 5.30, noise), Single
unchanged. 50/50 checks pass.

### Etc::Sieve: the byte list as Goose's `u8[>..]`

Medians of 7: 2.82 s against Goose/clang 2.50 (1.13×). The marking loop
was 9 instructions to Goose's 6: two checks, and the buffer's length and
block loaded again each time round. The port's sieve was an `arena`
`Buffer`, whose `set` is the port's C (`arena_buffer_set`, inlined from
bitcode): a C byte store, which may alias anything, so LLVM reloads the
buffer's handle after it. Goose's is a `u8[>..]`; the port now uses a
`List<U8>` (`List(limit + 1, 1)`), whose element stores carry the
compiler's byte tag. 2.82 → 2.56 s (Goose 2.50). 50/50 checks pass.

The same for ArithDecode's output: a `Buffer` pushed one byte per symbol
(the port's C, a store LLVM takes to alias anything), now a `List<U8>`
as Goose's `u8[>..]`: 1.316 → 1.280 s (Goose 1.124). The C runtime's
own tags could not help: C's TBAA and the compiler's have different
roots, which LLVM never separates.

### Etc::NeuralNet: the synapse checks

Medians of 7: 1.240 s against Goose/clang 1.081 (1.15×). Under callgrind
(60 iterations) the port runs 822 M instructions to Goose's 659 M, the
same 177 M in `exp` for both; `feed` 193 M to 169 M, `update` and `train`
443 M to 301 M. A synapse update is about 25 instructions to Goose's 15:
Goose names a synapse's neurons by unchecked 32-bit relative references,
and the port checks three indices for each: `j` against the neuron's
`Array<I32, 10>`, the synapse index against the list of synapses, and the
source against the list of neurons. The last two are indices loaded from
memory, which no pass can prove in range.

The first is a loop counter against a constant bound, which LLVM's
inductive range check elimination (IRCE, already in the pipeline) splits
off. It did not, because instruction combining had folded `j - 1 >=u 10`,
taken to the stop, into `j - 11 <u -10`, a form IRCE does not read.
`ZANE_INSIDE_FIRST=1` makes the check `j - 1 <u count`, taken to the
element. IRCE then reads it as `j <u 11` and, with
`-irce-skip-profitability-checks`, splits six of the port's loops. It is
worse all the same: 905 M instructions, 897 M with the split, against
822 M. The folded form gave `feed`'s loop a maximum trip count of 10,
which unrolled it in full, and the split's checked loops before and after
cost more than the check they save. Off.

NeuralNet stays at about 1.15×: the cost of the two checks of loaded
indices, which Goose's references do not make.

### Compress::LZWEncode: the hash's tail

Medians of 7: 0.743 s against Goose/clang 0.668 (1.11×). Under callgrind
(8 iterations) it is 506 M instructions to Goose's 465 M, and the same
algorithm: a key is a range of one byte list, hashed, probed for and
compared. `zane_bytes_hash` mispredicted twice as often as Goose's hash
(1.35 M to 0.68 M), on the branches after its word loop: on `n & 7`, then
on the tail's size. The tail is now taken as Goose's standard library
takes a short key's: the words before the last 8 bytes, then those 8 as
one load that may overlap. 0.743 → 0.736 s. 71% of the keys hashed are
32 bytes or longer, about 80 on average, so the time is the lanes rather
than the tail. The rest of the gap is spread over the hash, the compare
(`memcmp`, which misses the cache as often as Goose's `gs_memeq_long`
does) and the probe loop. 50/50 checks pass.

### Step 30: all 50 tests again

The binary after the LZW hash change, with the switches of `sw.sh`
(`ZANE_SHADOW_REFILL` and `ZANE_NO_COPY_IDIOM` now on), against both of
Goose's builds: three interleaved rounds, in `results/step30-goose.json` and
`results/step30-goose.md`. Geomean Zane / Goose-clang 0.973 (faster on 20 of 50;
step 29 0.984, 19), Zane / Goose-gcc 0.834 (faster on 34; step 29 0.833).

Since step 29: Sieve 1.21 → 0.92, Fannkuchredux 1.20 → 1.07, Matmul::T16
1.13 → 1.05, ArithDecode 1.18 → 1.12, LZWEncode 1.15 → 1.13. The worst
now: ArithEncode 1.39, Maze::Generator 1.29 (1.19 at step 29; this test
swings), LogParser 1.26, SHA256 1.23, NeuralNet 1.18 (the synapse checks
above), HuffDecode 1.16, Matmul::T8 1.15 (1.09 at step 29; T8 and T4
swing by as much between rounds), Graph::BFS 1.15, CSV::Parse 1.14,
Binarytrees::Obj 1.14.

### Compress::HuffDecode: the push's count, the current node's check

Medians of 7: 0.846 s against Goose/clang 0.778 (1.09×). Under callgrind
(35 iterations) it is 1,912 M instructions to Goose's 1,465 M. Half the
bits reach a leaf. A bit is 14 instructions to Goose's 10, and a leaf 9
to 7. Goose follows unchecked node pointers; the port follows checked
32-bit indices into the node list, scaled by 16 each time. The check of
the current node repeats at every bit, though on the path from a node
that is not a leaf the current node is the child just checked. The push
loaded and stored the output list's count in the frame.

Frame_shadow had left the count and the room out of its slots: one
`<2 x i32>` store wrote both (`ZANE_FRAME_SHADOW_WHY=1` now prints each
rejected offset and the accesses that overlap it). `ZANE_SHADOW_SPLIT=1`
makes such a vector load or store of the frame one per element first.
Both are then slots and the load goes, but the frame is escaped, so each
store stays: 1,912 → 1,897 M instructions, 0.846 → 0.856 s, within the
noise. Off. Constraint elimination and jump threading added to
Frame_shadow's passes (`ZANE_SHADOW_AGAIN`) did not remove the repeated
check: 1,912 M.

### The regex engine moves into core

`zane/lib/arena/rx.zn` and its tests are gone: the engine is now core's
`regex` package (zane-lang/core branch `regex`, pinned at f6756e2 until it
merges), with a public API (`regex$compile`, `Regex:count`, `findAll`,
`captures`), anchors, word boundaries, inline flags and capture groups.
LogParser and Template::Regex import it qualified (`import regex;`), since
`arena`'s own `Regex` would collide; LogParser's case-insensitive patterns
gain `(?i)`. Checksums are unchanged.

Built as a library, the engine is 7–8× slower than as part of the program:
LogParser 2.2 s against 0.3 s, Template::Regex 12 s against 1.4 s. A
library object keeps every snapshot (the compiler's lowering.md §9), so
each read of the DFA's transition list in `_findEnd` calls `zane_snapshot`
(147 M calls under callgrind). The fix belongs in the compiler: a
dependency compiled for a program build gets the program's write-back
places. Until it lands, these two rows measure that, not the engine.

Core's `regex` merged (zane-lang/core#19, cdd6570) and requires compiler
v0.39, which carries the fix (zane-lang/compiler#390, #391; the CLI side is
zane-lang/zane#40, #41). The pins follow. Medians of 3 now: LogParser 0.70 s,
Template::Regex 3.68 s, against 0.25 s and 1.3 s for `rx.zn` inside the
program. The snapshots are gone from `_findEnd`; what is left is that core is
a path dependency here (`from /home/user/core`), and the CLI compiles a path
dependency unoptimized on every build, so the DFA loop keeps every value in
the frame. Under callgrind `_findEnd` is 8.5 G instructions to `findEnd`'s
2.1 G, with the same skip-loop calls. A `source` dependency is compiled
optimized; switching core to one needs a core tag that has `regex`.

Core is a `source` dependency now (`core v0.13 source`; v0.13 is cdd6570),
which the CLI compiles optimized. Medians of 5: LogParser 0.28 s against
0.25 s for `rx.zn` inside the program; Template::Regex 2.07 s against 1.3 s.

Core at v0.14 (810332e), whose `_spans` runs the forward and reverse DFAs
directly instead of building a list per match (zane-lang/std#20). Medians of
5: LogParser 0.26 s and Template::Regex 1.26 s, against 0.25 s and 1.3 s for
`rx.zn` inside the program. Both are at par with it now.

### Step 31: all 50 tests, released toolchain

The port as a user builds it: compiler v0.39 (the release, no switches),
core v0.14 as a `source` dependency. Against Goose v2026.4 (the release
archive; the port's C at `-O2` by gcc 13 and clang 18) and LangArena's C
(`make prod`). All 50 checks pass on all four. `tri.py 3`, pinned to CPU 2,
interleaved; `results/step31-goose.json`, table by `rep4.py` in `results/step31-goose.md`.
Geomeans: Zane / Goose-clang 0.974 (faster on 22 of 50), Zane / Goose-gcc
0.792 (faster on 36), Zane / C 0.642 (faster on 32).

Worst against Goose-clang: ArithEncode 1.36, SHA256 1.31, LZWEncode 1.24,
LZWDecode 1.22, Graph::BFS 1.22, LogParser 1.20, Sort::Quick 1.20,
Calculator::Ast 1.19. Template::Regex 1.07 (C 0.67). Against C, Zane is
slower on CacheSimulation 1.26, Sort::Quick 1.19, Base64 1.14–1.16 and
Brainfuck 1.10–1.12. This container runs every binary faster than step 30's
did, so compare ratios, not seconds, across steps.
