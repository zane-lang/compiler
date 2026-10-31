# Zane against Goose: findings

Status: **finished**. This is the summary of the experiment. `README.md` is
the full log, with every step's measurements and the dead ends in the order
they happened. Like the log, this describes experimental work: the spec repo
was not updated, and where the new model departs from the spec, the last
section says so.

## The question

Goose (<https://github.com/aardappel/goose>) has no heap: its dynamic data
lives on data stacks that are reset, never walked, and its trees are pools
linked by 4-byte relative references. On langbench's allocation-heavy
tests it was well ahead of Zane v0.20. The question was where Zane's gap
came from, and how much of it Zane's own model could close without giving
up what Goose gives up (resizable values anywhere, types that contain
themselves).

## The answer, in numbers

Median wall time and peak memory. The baseline ratio is v0.20 against Goose
in the same run; the final numbers are the default build at the end of the
experiment (`results-defaults.txt`, 3 runs each, a cloud container whose
wall clock moves by about ±15%). A ratio below 1 means Zane is faster.

| test | v0.20 ÷ Goose | final Zane | final Goose | final C | final ÷ Goose |
| --- | --- | --- | --- | --- | --- |
| binarytrees | 2.3× | 0.042 s, 9.5 MB | 0.059 s, 9.5 MB | 0.288 s | 0.71× |
| treecopy | 1.7× | 0.097 s, 22.1 MB | 0.196 s, 18.1 MB | 0.597 s | 0.49× |
| allocfree | 1.7× | 0.296 s, 32.6 MB | 0.708 s, 43.9 MB | 2.916 s | 0.42× |
| listgrowth | 2.8× | 0.223 s, 63.1 MB | 0.211 s, 63.0 MB | 0.670 s | 1.06× |
| ntree | 2.3×, 44.9 MB | 0.151 s, 23.5 MB | 0.113 s, 24.7 MB | 1.148 s | 1.34× |
| entities | 1.1×, 158 MB | 1.111 s, 93.7 MB | 1.063 s, 93.6 MB | 1.067 s | 1.05× |
| concscan | 0.1×, 158 MB | 0.400 s, 93.6 MB | 3.649 s, 162.5 MB | 0.385 s | 0.11× |

The compute-bound tests (trialdiv, mandelbrot, fannkuch, nbody,
spectralnorm, particles), startup and primes were level with Goose and C
before, and still are.

Zane now matches or beats Goose everywhere except ntree. ntree's remaining
gap is the 16-byte list handle each node is, against Goose's 4-byte links.
Even so, Zane's ntree takes less memory than Goose's. A port that holds a
node's children in an `ArrayRef` the way Goose's does (`ntreearray/`) is
1.5× faster than Goose in 40% of its memory, so the gap is the program's
container, not the language. gameloop is left out of the comparison: it
measures how the port stores its entities, not a mechanism the languages
differ in.

## What we found

**Most of the gap was representation, not allocation.** Zane's regions
were never the slow part. What cost Zane was how many blocks a value took,
how wide its links were, and how big its handles were:

- **Too many boxes.** Plain binarytrees made three blocks a node, 48 bytes,
  where Goose made one of 8, because every member whose type led back to
  its holder was boxed. One box per cycle is enough.
- **8-byte links and 24-byte handles.** A tree node full of 8-byte
  pointers, or a list of children each a 24-byte handle, is two to three
  times the memory of Goose's node. That memory is the time on the
  tree tests.
- **Memory held longer than needed.** A list that outgrew its block kept
  both copies until its region drained, and a fresh large list faulted in
  new pages every time. These two were the whole gap on entities,
  concscan, allocfree's system time and listgrowth's page faults.

**Goose's speed on a push is its shape, not its stacks.** Goose's push has
no capacity check and keeps its top in a register through a loop. Zane gets
the same shape where it can prove a loop's pushes, by making room for them
before the loop. A C replay of binarytrees ran as fast as Goose once its
push had that shape.

**A lead hides a loss.** Once Zane was level, whole-program times stopped
showing what Goose or C still did better in parts of a program.
`mechanisms.py` lines up each function's own instructions (Callgrind)
across Zane, Goose and C, and found the remaining mechanisms: a scope
opened per loop pass, index checks that LLVM could not hoist, and a second
loop counter.

**Goose's memory model was not worth copying.** Goose computes how many data
stacks a program needs and proves that at most one growable value lives on
each, at the top. It pays for this in the language: an array element may
not be resizable, a type may not contain itself, and trees must be pools
the program declares. Goose rejects a stack per container itself ("a
JSON document has thousands of containers; a reservation each is
absurd"). Zane's regions do the same job without those restrictions. What
Zane took from Goose is the width of its links, not its stacks.

**32 bits are enough for a reference and for a box, without fixing where
memory lives.** A reference only ever names a frame's slot or a global, so
it fits as a distance from the program's image. A box's block fits as a
distance from the image in 8-byte units, if the runtime keeps its chunks
within 16 GiB of the image. That gives a position-independent program. The
alternative that was built first, a fixed 28 GiB range of addresses (the
"cage"), gained only ntree's last 5 MB and was removed.

**The rest was noise or a dead end.** These were measured and not kept:

| idea | result |
| --- | --- |
| the cage (`ZANE_REF32`), every reservation in 4–32 GiB | removed: fixed range, not position-independent; its only lead was ntree's 18 MB against 23 |
| 32-bit list items | declined: a growing list reserves 64× its size, which no 32-bit window holds |
| chunk-numbered boxes (`ZANE_CHUNK_BOXES`) | about 5% slower than image boxes on binarytrees, same memory; kept opt-in for platforms where the window cannot be placed |
| bump-only regions (`ZANE_BUMP_REGIONS`) | no gain: the frontier's load and store were the chain, not the free list |
| pool reuse (`ZANE_POOL_REUSE`) | no gain: pools already grew in place in warm memory |
| loop ranges (`ZANE_LOOP_RANGES`) | slower: the range test cost more than the checks it removed |
| a stack per dynamic value, as Goose does | not built: see Goose's memory model above |
| lowering IRCE's minimum iterations | slower; reverted |
| aligning loop heads to 32 bytes | no effect |

The pooling prototypes (`ZANE_POOLED_VARIANTS`, `ZANE_PACKED_NODES`,
`ZANE_POOL_REGISTERS`, `ZANE_POOL_UNCHECKED`) worked: they put a recursive
variant's tree in one pool with 4-byte links, and brought treecopy to 0.6×
Goose. The default model now gets binarytrees and treecopy further without
them, so they stay opt-in.

One finding was about the machine rather than Zane. On the container's
Intel Xeon, glibc's `memmove` runs at about a byte a cycle when it moves
4 KiB or more by less than 64 bytes, because it uses `rep movsb`, and this
processor runs that slowly over a short distance. An ordered removal from
a list of small elements is exactly that move, so such removals now move
in 2 KiB pieces.

## The new model

On a Linux target, the default build is:

**References** are 32 bits: a stored `&T` is its signed distance from the
program's image (`__ehdr_start`). Every context's frames come from one area
in the 2 GiB right below the image, and globals sit in the image, so every
reference fits. Decoding is one address computation, with no load.

**Boxes** are 32 bits: a boxed member is its block's signed distance from
the image in 8-byte units, which reaches ±16 GiB, and 0 is null. The
runtime carves every 1 MiB chunk from a window it reserves once, from
16 GiB to 2 GiB below the image, or above the image where the program is
loaded too low for that (as under Valgrind). Chunks inside the window are
reused in any order; only their distance from the image is bounded.

**A recursive type takes one box per cycle.** A variant's payload that
leads back to it is boxed; a struct member on the same cycle is not,
since that payload's box already breaks the cycle.

**A sum of nothing or a box is the box alone**: `[Void; Box]` and
`[Void; Ref]` are one 4-byte word, 0 for the empty case. So a binarytrees
node is 8 bytes, as Goose's is.

**A list's handle is 16 bytes**: an 8-byte items pointer, a 32-bit count
and a 32-bit room counted in elements, so a list holds up to 2^32 − 1
elements. A list's first block holds four elements, rounded to a word and
clamped to 32–128 bytes, and comes from the region's size classes like a
box's. A list that grows past a chunk gets a reservation 64 times its size
so it can keep doubling in place, and a drained region keeps two such
reservations warm for the next large list. A list that moves out of its
block decommits the old block chunk by chunk as it copies.

**Codegen**, all on by default:

- *Light scopes*: a scope that nothing can put a block in, with a frame of
  4 KiB or less, uses the machine stack and opens no region.
- *Loop pushes*: a loop's pushes onto a list no other statement of the loop
  can change get their room made once before the loop, and the count is
  kept in a register through it. A whole-program analysis finds the
  functions that cannot change any list's count, so calling one does not
  block this.
- *Handle hoisting*: a counted loop whose body cannot change a list's
  handle reads each indexed list's items and count once, before the loop,
  so LLVM can remove the index checks.
- *Partial inlining*: a recursive function's base case is copied into its
  callers, so building a leaf is not a call.
- *Ordered removals* of elements under 64 bytes move in 2 KiB pieces.

**Runtime**: `zane_arrive` returns at once when the slot is in the open
scope's own region, the common case.

**Every switch can be turned off** by setting it to `0` when compiling:
`ZANE_ONE_BOX`, `ZANE_PARTIAL_INLINE`, `ZANE_LOOP_PUSHES`,
`ZANE_LIGHT_SCOPES`, `ZANE_HOIST_HANDLES`, `ZANE_FRAME_REFS`,
`ZANE_IMAGE_BOXES`, `ZANE_NICHE_SUMS`.

### Limits

- The compact layout is Linux-only. It needs the ELF linker's
  `__ehdr_start` and Linux's `MAP_FIXED_NOREPLACE`. On other targets
  (`--target`, or a host that is not Linux) references, boxes and handles
  keep their 64-bit layout. `ZANE_CHUNK_BOXES=1` is the drop-in for a
  platform that cannot place the window, at about 5% on box-heavy code.
- A program's chunks share 14 GiB of addresses. Large lists are not in
  them; their reservations are anywhere.
- All contexts' frames share the 2 GiB below the image.
- If the window or the frames area cannot be reserved, the program stops
  with an error rather than falling back, since the encoding is chosen when
  the program is compiled.
- A list holds at most 2^32 − 1 elements.

## How it changed from v0.20

| | v0.20 | now |
| --- | --- | --- |
| stored reference | 8-byte pointer | 4-byte distance from the image |
| boxed member | 8-byte pointer | 4-byte distance from the image, in 8-byte units |
| boxes on a cycle | one per member that leads back | one per cycle |
| `[Void; Box]` | 8-byte tag + 8-byte payload | 4 bytes |
| list handle | 24 bytes: pointer, 64-bit count, 64-bit room in bytes | 16 bytes: pointer, 32-bit count, 32-bit room in elements |
| list's first block | fixed 128 bytes, 64-byte aligned | four elements, word-aligned, 32–128 bytes |
| frames | anywhere | one area in the 2 GiB below the image |
| chunks | anywhere | a window within 16 GiB of the image |
| an outgrown list block | held until its region drains | decommitted as it is copied |
| large list reservations | fresh each time | two kept warm per context |
| a scope with only scalars | opens a region | uses the machine stack |
| a loop of pushes | checks room on every push | makes room once before the loop |
| an indexed loop | reloads the handle and checks every index | reads the handle once; LLVM drops the checks |
| a recursive base case | a call | inlined into its callers |
| codegen tests | 64-bit layout | Linux golden files carry the compact layout; layout facts follow the target |

## Where it departs from the spec

The spec was not updated, as this was an experiment. Adopting the model
would need these spec changes:

- **One box per cycle** contradicts adt.md §4, which boxes every member
  whose type leads back to its holder.
- **The 2^32 − 1 element cap** on a list is new.
- **The 32-bit layouts** of references, boxes, the niche sum and the list
  handle are implementation choices. They matter wherever the spec states a
  size or a layout.
- **The platform split** (compact on Linux, 64-bit elsewhere) means a
  value's size depends on the target.

## What is still open

- **ntree**: closing the last 1.3× needs the node's children inline, as the
  `ArrayRef` port shows, or a smaller handle; the 12-byte handle was
  declined above.
- **listgrowth** (1.06×): Goose unrolls the push loop twice; Zane keeps a
  second counter.
- **A pool's count through calls**: a calling convention that passes a
  pool's items and count in registers and returns the new count would keep
  the count out of memory between frames. The C replay showed it beating
  Goose; it was not built.
- **Hardware counters**: part of binarytrees' gap was below what Callgrind
  models (store forwarding, the TLB). This container has no hardware
  counters, so measuring it is left for a machine that has them.
- **Windows and macOS**: the compact layout is untested there, and would
  need the window placed by other means, or chunk-numbered boxes.
