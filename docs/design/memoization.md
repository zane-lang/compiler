# Memoization: calls remembered while the program runs

Every build gives some functions a table of the results of their calls, and
a call whose arguments are in the table returns the remembered result
instead of running. `--no-memoize` builds without the tables
([zane-lang/compiler#262](https://github.com/zane-lang/compiler/issues/262)).
The pass that picks the functions and rewrites the program is
`lib/cgt/memo.ml`. It runs on the finished code-generation tree, after stage
5 when there is one. Codegen (`lib/codegen/memos.ml`, `memo`) emits each
table. `dev/bench/memo/` holds the programs it was measured on and the
results.

## M1. Which functions get a table

A function gets a table when:

- **Its result depends only on its arguments.** A function, or a method
  without `mut`, writes nothing its caller can see
  ([`effects.md` §3](https://github.com/zane-lang/spec/blob/b480975/spec/effects.md#3-what-each-kind-of-verb-may-write)).
  Besides its arguments, it reads package constants, which hold the same
  value on every call
  ([`packages.md` §5.1](https://github.com/zane-lang/spec/blob/b480975/spec/packages.md#51-packages-contain-no-mutable-variables)).
  A constant is made by its first read, so the miss that computes a result
  has made every constant the result depends on. A capability reaches a
  function as a reference argument, which the next rule keeps out of the
  key. The root package's verbs also reach the console and the runtime by
  name, and may print with them
  ([`effects.md` §6.6](https://github.com/zane-lang/spec/blob/b480975/spec/effects.md#66-the-programs-console-and-runtime)).
  So the function's body, and the body of every function it calls, names
  neither, makes no call through a function value, and calls no runtime
  function that outputs, reads the program's arguments or spawns. A callee
  with no body here rules its caller out.
- **Its arguments and result are fixed-size values.** These are scalars, and
  structs, enums, variants and arrays of them, with no handle or address
  anywhere inside. A value of one of these types is its bytes, so equal bytes
  mean equal values. A string or a list owns a block, and a reference names
  an object whose owner can change it between calls, so neither is its
  bytes. The arguments may take at most eight words, and so may the result.
  A value of scalars only takes one word for each scalar, and any other
  value a word for each eight of its bytes.
- **It calls back into its own cycle of calls, or it is heavy and called in
  a loop.** A recursion's table pays when its arguments repeat, within one
  call, as a search reaches a position twice, or across calls, as a loop
  asks for the same depth again. A function outside any cycle gets a table
  when a loop in another function calls it and one call runs at least twice
  the operations of a lookup (M3), so a hit saves more than its lookup
  costs. A call's operations estimate what an optimized build runs: one for
  each computation, memory access and branch, a loop's body as often as a
  constant count says or else eight times, a switch's dearest case, and one
  for each call plus the operations of the function called. Naming a local,
  a constant or a verb's expansion counts nothing, since an optimized build
  keeps it in a register or folds it away. A light function in a loop gets no table, nor does a
  heavy one called outside any loop, whose arguments repeat only if the
  program calls it again.

The choice reads the tree alone, never what LLVM makes of the program. So
the two tiers of a tiered build, which lower the same tree, plan the same
tables and emit the same module ([`tiers.md`](tiers.md) T3).

In a program that spawns, and in a library, whose functions a program that
spawns may call, every thread uses one table for each function, so a result
one thread made can be a hit on every other while its entry holds it. A
remembered function reads only its arguments and constants, so the result
is the same whichever thread made it. The entry's meta word then guards it:
above the work it keeps a version, which a miss makes odd while it writes
the entry and even again after. A lookup reads the meta word, then the entry, then the meta word
again after an acquire fence, and takes the entry for a hit only when both
reads are the same word with an even version. Every write changes the
version, whichever arguments it is for, so a lookup never returns an entry
written while it read. A miss claims the entry by swapping its meta word
for one with an odd version, writes it only when no other miss held it,
and publishes it by storing the meta word with the version even again and
its work; a miss that finds it held leaves it, which costs at most a later
miss. The version has 23 bits, so a lookup is misled only when 2^22 writes
of its entry fall between its two reads. No word is spent on the guard.
The state and the count of work stay each thread's own, as thread-local
variables: the count measures the calls of one thread's stack, and the
state is written on every lookup, which threads sharing it would contend
for. A stamped dependency is built as a library, so its functions keep
tables in its object, which the program's calls into it use; the bodies the
program takes in to optimize with get none. A program that spawns nothing
keeps plain entries, which no miss marks.

## M2. A function becomes four

A function given a table becomes:

- **A gate, under its own symbol, inlined into every caller.** It reads the
  function's state, and calls the plain copy once the function has stopped
  looking, or the lookup otherwise.
- **The lookup, which is never inlined.** It hashes the arguments' words and
  probes one entry of the table. On a hit it returns the remembered result.
  On a miss it runs the body copy and writes the entry over, when no other
  thread is writing it (M1).
- **The body copy, the function as written.** Its calls back into the cycle
  go through the gates again.
- **The plain copy.** Its calls into the cycle go straight to the other
  plain copies, so it runs as the function did before.

The table is direct-mapped and holds at most 256 KiB per function: as many
entries as fit, a power of two, and at most 16,384. Each entry is the
argument words, the result words, and a meta word holding the work the
result took, and the version when threads share the table. An empty
entry's work is 0, and a written one's at least the weight of its
function's cheapest call, so a lookup never takes an empty entry for a hit,
even for arguments of zeros, whose words it matches. A miss writes over
whatever entry was there. The table is zero-initialized memory, which the
system backs only where an entry has been written. On `dev/bench/memo`,
256 KiB against 64 KiB and 1 MiB: `ttt`, whose positions outnumber a
smaller table's entries, ran in 3.7 ms against 5.4 and 4.1, and `overlap`,
whose repeats are all recent, in 3.4 ms against 2.9 and 4.3, a bigger table
costing it the first write to each page (wall clock, the least of 40 runs,
process start of about 2.5 ms included). The other layouts measured, and
why each lost, are in [`memo-tables.md`](memo-tables.md). The table starts on a
cache line, so where it lands in the binary does not decide which entries
straddle two: on `tests/perf` `depths`, a table that landed 16 bytes past
one missed the first-level cache 72% more often.

A value of scalars only is taken apart into one word per scalar. Any other
value is copied into a zeroed buffer of words. The bytes such a value leaves
undefined, its padding and the room past a smaller case's payload, are
frozen first, so comparing them compares fixed bits: the worst they can
cause is a miss, never a hit LLVM made up.

## M3. A function stops looking when looking does not pay

Each function's state is a score, in sixteenths of one of its calls:

- **A lookup adds the function's charge.** The charge is the lookup's
  estimated cost, a few dozen instructions plus a few for each word of key,
  measured against the estimated weight of one call. That weight is a node
  for each node of its body, a loop's body eight times over, and the weight
  of each function it calls that has no table. The charge is between a
  sixteenth of a call and four calls.
- **A hit subtracts the work it saved.** The work a result stands for is
  what the calls that computed it would run without a table, counted from
  below: each miss adds the weight of its function's cheapest call, and each
  hit adds the work its own result stands for. The entry keeps that count,
  and a hit is credited with it, measured against the weight of one call.
- **The score never goes below zero.**

Once the score reaches 128 calls, the function stops looking for the rest of
the run, and its gate sends every call to the plain copy. So a function whose
arguments rarely repeat, or whose repeats save less than its lookups cost,
pays for a bounded number of lookups and then runs as it would have.
Because the charge is relative, a function whose calls are heavy can look up
for a long time before its hits start to pay, as a search does before the
first position it reaches twice. One whose calls are light gives up after a
few dozen lookups.

The cheapest call is the shortest path through the body to a return,
weighed as above, with a loop run as often as a constant count says, and any
other loop run no times. A `return` inside a verb written out where it is
called ends the verb, not the function, so the path goes on after it. Every call the hit skipped
would have run at least that, whichever path it took, so the credit never
exceeds what the hit saved. A recursion whose arguments repeat only where it
bottoms out hits on half its calls, each saving one call of its cheapest
path, and stops looking (`tests/perf/leaves`). The count is low for a call
whose base case loops as often as an argument says: its rounds are not counted, and such a function can
stop looking though its hits would have paid (`lv1h20`,
`dev/bench/memo/`).

## M4. A loop decides once

A loop that calls a function with a table from outside that function's cycle
runs in one of two versions, chosen before its first round:

- **When every function the loop calls through a gate has stopped looking,**
  the loop runs as written, with each of those calls made to the plain copy.
  Nothing in it reads a state, so LLVM may optimize it as it would the
  original.
- **Otherwise a second copy of the loop runs,** calling through the gates.
  Before each round it checks whether those functions have all stopped. If
  they have, it leaves, and the first version runs the rounds that are left.

Without this, every call from a loop would read its function's state, a few
instructions that showed when each call did little (5% on `shallowin`,
`dev/bench/memo/`). The second copy's ids are numbered afresh, since one
numbering covers a function's locals, scopes and labels.

## M5. What a remembered call changes

A hit returns what the body would have returned for the same arguments, so
the program computes and outputs the same. What can change is how far its
calls nest. A hit skips the calls the body would have made, so a program
that would have stopped because its calls nested too deep may finish
instead. How deep calls may nest is the implementation's limit, not the
spec's.
