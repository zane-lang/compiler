# Tiered builds: start plain, finish optimized

> **Status: built.** This page says how a program starts as soon as its
> fastest build is made and moves to optimized code while it runs, which is
> how `zane run` and `zane test` build. Each decision is numbered (**T1**…).

An unoptimized build is made in a fraction of the time an optimized one
takes, and runs several times slower ([`optimization.md`](optimization.md)
O12). Which of the two gives a program's result sooner depends on how long
the program runs, which no build can know. A tiered build does not choose. It
makes both at once, starts the program as soon as the fast one, **tier 0**,
is linked, and moves each of its functions to the optimized build, **tier
1**, once that is built. A program that ends before tier 1 is ready has lost
nothing to the optimizer, and one that runs longer finishes on optimized
code.

---

## 1. The two builds

**T1. `--build OUT --tiered` makes tier 0, and `--tier-up OUT` makes tier
1.** Both take the packages and flags a plain build takes, and the caller
runs them at once, as two processes: tier 0 is linked and started while tier
1 still compiles. Tier 0 is an executable; tier 1 is a shared library
(`.so`, `.dylib` or `.dll` by target). Neither takes `--optimize`, and tier 1
takes no `--link`, since it links nothing of the program's (T4).

**T2. Tier 1 is a lighter optimized build than `--optimize`.** It skips
stage 5, runs the optimized build's passes ([`lowering.md`](lowering.md)
§9, "The passes") with runtime loop unrolling off, and generates optimized
machine code (`Passes.tier1`). Runtime unrolling is what made `-O2` take 16 s
of a 400-function program's 25 s build, against 2 s without it, for code
about 5% slower; stage 5 takes seconds on programs that compute much ahead of
time. A tier 1 that arrives late gains the program nothing, so it is built
for its arrival rather than for the last few percent: on that program it
gave a result in 10.6 s, against 18.3 s plain and 31.8 s optimized.

**T3. Both tiers emit the same module, and each carries its fingerprint.**
Tier 1 lowers the tree tier 0 does, since it skips stage 5, and plans what
it remembers from that tree alone ([`memoization.md`](memoization.md) M1).
So the two emit the same LLVM module, and each takes a hash of it before
anything changes it (`Tiers.fingerprint`). The runtime loads tier 1 only
into the program whose fingerprint it carries, so a library left from
another program, or from the same program before an edit, is never run.

---

## 2. How tier 1 reaches tier 0's functions

**T4. Tier 0 calls its own functions through slots.** After its passes,
tier 0 gives each function it defines a slot, a variable holding the
function's address, and makes every direct call to one a load of its slot
with acquire ordering and a call through it (`Tiers.tier0`). Every other use
of a function, a function value such as a lambda or a spawned call's body,
is made a use of an entry function that calls through the slot, so it moves
to tier 1 too. Each slot is listed under its key, the function's symbol and
LLVM type, so a body fills only a slot of its own type. A call already
running finishes in tier 0, since its code cannot change under it; the next
call of the function runs tier 1. Work written inline in `main`, which is
called once, stays in tier 0.

**T5. Tier 1 imports everything it does not define.** Before its pipeline,
tier 1 keeps every function it defines to itself, lists each under its key
(`zane.tier.defs`), and makes each variable whose value changes while the
program runs, a package constant's or a memo table's, a declaration. After
the pipeline, every use of what it does not define — the runtime's functions
and variables, a dependency's functions, those variables — is made a load
from its import table (`Tiers.tier1_imports`, `tier_stubs.cpp`). A
thread-local variable has an address only on a thread, so for one the table
holds a function of tier 0's that gives the asking thread's. Tier 1 so has
one copy of each of these, tier 0's, and each package constant is made once.
It links against the C library alone, for what LLVM itself calls, such as
`memcpy`, and needs nothing exported from the program: one mechanism serves
ELF, Mach-O and COFF, where a DLL may not leave a symbol undefined.

A use of an import that is a constant no function holds, such as another
variable's initial value, cannot be a load, and tier 1's build fails with
the name of the import. The program then runs in tier 0, as it means the
same.

Since tier 1 calls tier 0's runtime, tier 0 links the runtime an optimized
build does, compiled with `-O2` (`Build.executable`), so its allocation,
scope drains and list growth run in tier 1 as fast as in an optimized
build. Linking the unoptimized runtime instead, the tiered `returns` and
`texts` perf programs took about twice the estimated cycles, and `stress`
7% more ([`tests/perf/`](../../tests/perf/README.md)). Compiling the
runtime with `-O2` takes about a third of a second longer, once for each
cache, and a release bundles it already compiled.

Tier 1 also takes the runtime's bodies for LLVM to inline, and tier 0
takes the same ones before it makes its table (T6), so it exports every
runtime function and variable they reach. Neither tier takes a body that
calls outside the runtime, so the table gains no C library function, each
of which would be a symbol for the loader to look up as every run starts.

Tier 1 takes bodies only, never the whole runtime an optimized executable
takes into its module ([`lowering.md`](lowering.md) §7). Tier 1 is loaded
into a process whose runtime is already running, tier 0's, and the
runtime's state is that process's: its page table, its contexts, its
output buffer and their locks. A whole runtime in tier 1 would be a second
copy of that state, which tier 1's calls would read and change while tier
0's runtime kept the first. So tier 1 copies a function's code only where
the copy reaches the one state there is through tier 0's table, and every
other function stays a call into tier 0's runtime: one that reads a
`static` variable, which has no name tier 0 could export, or that takes
the address of a function of the runtime's own, which a copy would not
share. A body inlined into tier 1 reads a thread's variable, such as
`zane_self`, through tier 0's function for it (T5), a call where an
optimized executable reads it at its offset.

**T6. Tier 0 lists what tier 1 may import.** Before its passes, tier 0 makes
a table of every name tier 1 may take, with its address
(`zane.tier.exports`): each function and variable the module declares, each
body it has only to inline, and each changing variable. Both tiers read that
list from the same module (T3), so it holds every name tier 1 asks for. The
table also keeps each of them through tier 0's passes.

---

## 3. The swap

**T7. The start function hands the runtime the slots.** Tier 0's entry
calls `zane_tier_up` first (`runtime/tier.c`), with its fingerprint, slots
and exports. When `ZANE_TIER_UP` names a file, a thread of the runtime's
waits for it, a millisecond at a time for the first tenth of a second and
five after, loads it (`dlopen`, or `LoadLibraryW` on Windows; a name
without a directory is the current directory's file), and checks
its fingerprint. It fills tier 1's imports from tier 0's exports by name,
then points each slot at tier 1's function of the same key with a release
store, so a call that reads the new address sees the imports filled. A
library that does not load, is another program's, asks for a name tier 0
does not have, or lacks one of tier 0's functions leaves the program wholly
in tier 0, and says so only when
`ZANE_TIER_LOG` is set. The program removes the variables once read, so
nothing it starts sees them. A program ending while tier 1 loads, by returning
from `main` or by an `exit` such as a runtime error's, waits for
the load to finish, since a process that ends while another thread holds the
loader's lock can hang.

**T8. `ZANE_TIER_WAIT=1` loads tier 1 before `main` runs.** It is for the
tests: the whole program but `main` itself then runs tier 1, and a tier 1
that is not there yet, does not load, or lacks a function stops the
program, so a test cannot pass on tier 0 alone, and one whose tier-1 build
failed does not wait for it.

---

## 4. Delivering tier 1

**T9. Tier 1 arrives whole.** `--tier-up OUT` makes its files in
`OUT.work/`, which it removes after, writes the library beside `OUT`, and
renames it into place, so the program never loads half a library. A caller
removes `OUT`, `OUT.partial` and `OUT.work/` before a run, so a library or a
stopped build's files from an earlier run are never taken for this one's.

**T10. The cache keeps the newest 32 tier-1 libraries.** A library is kept
in the cache directory ([`lowering.md`](lowering.md) §7) under `tier/`, named
by a hash of the module's fingerprint, the target, the C compiler and what
it says it is, the runtime's bitcode compiler and what it says it is when
that is another one (`ZANE_BITCODE_CC`), this compiler's file, and T2's
pipeline. A later `--tier-up`
of the same module copies it after lowering and emitting, without running
LLVM or the linker, so a program run again unchanged moves to tier 1 within
its first moments. Taking one marks it newest; keeping one past 32 removes
the oldest.

**T11. A shared library is linked as a program is.** The link runs through
the same command a program's does ([`lowering.md`](lowering.md) §7): asked of
the C compiler once with `-shared` and kept, or bundled with a released
toolchain beside the program's, and run by the LLD in the compiler. On
Linux a program links `-ldl` as needed, since only glibc before 2.34 keeps
`dlopen` there, and a later one's empty `libdl` would cost every run its
loading; macOS's libSystem and Windows' kernel32 hold `dlopen`'s equivalent
already.

---

## 5. How the CLI runs it

`zane run` and `zane test` run each program the same way (zane
`docs/design/cli.md` §2.4): they start `--tier-up` in the background, build
tier 0, and run it with `ZANE_TIER_UP` naming tier 1's file beside it. A
tier-1 build still going when the program ends is stopped. A compiler
release older than the first one with tiers builds the program unoptimized,
as before.

---

## 6. What it is measured by

`tests/codegen/` builds every fixture tiered too, runs it with tier 1 loaded
before `main` (T8), and holds it to the golden file the plain and optimized
builds are held to. `tests/tiers/` runs a program that moves to tier 1 while
it runs, and the libraries the runtime must refuse. `tests/perf/` measures a
third build of each program, `tiered`, run as T8 runs it.
