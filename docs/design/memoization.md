# Memoization: calls remembered while the program runs

`--memoize` gives some functions a table of the results of their calls, and a
call whose arguments are in the table returns the remembered result instead
of running. It is opt-in, in plain and optimized builds alike
([zane-lang/compiler#262](https://github.com/zane-lang/compiler/issues/262)).
The pass that picks the functions and rewrites the program is
`lib/cgt/memo.ml`. It runs on the finished code-generation tree, after stage
5 when there is one. Codegen (`lib/codegen/emit.ml`, `memo`) emits each
table, and `lib/codegen/codegen.ml` (`still_called`) runs the optimized
build's extra check. `dev/bench/memo/` holds the programs it was measured on
and the results.

## M1. Which functions get a table

A function gets a table when:

- **Nothing it does can be seen but its result.** A function, or a method
  without `mut`, writes nothing its caller can see
  ([`effects.md` §3](https://github.com/zane-lang/spec/blob/baa2afa/spec/effects.md#3-what-each-kind-of-verb-may-write)).
  What remains to rule out is reading state that can change between calls,
  and the root package's console. So its body, and the body of every
  function it calls, reads no package variable, makes no call through a
  function value, and calls no runtime function that outputs, reads the
  program's arguments, makes a constant or spawns. A callee with no body
  here rules its caller out.
- **Its arguments and result are fixed-size values.** These are scalars, and
  structs, enums, variants and arrays of them, with no handle or address
  anywhere inside. A value of one of these types is its bytes, so equal bytes
  mean equal values. A string or a list owns a block, and a reference names
  an object whose owner can change it between calls, so neither is its
  bytes. The arguments may take at most eight words, and so may the result.
  A value of scalars only takes one word for each scalar, and any other
  value a word for each eight of its bytes.
- **It calls back into its own cycle of calls at least twice.** A call inside
  a loop counts twice. This is where a table can turn work that doubles at
  each level into work linear in the depth. A function that calls itself
  once gets nothing back from a table it fills on the way down.
- **An optimized build still calls it.** The build runs LLVM's `-O2` over
  the program without tables first, and leaves out every function that no
  other function calls afterwards. When LLVM has inlined and folded every
  call to a function, a table would only stop it doing so.

Only a program that runs on one thread gets tables: no package of the
build spawns, and it is not a library, whose functions a program that spawns
may call. The tables are not shared safely between threads. This is the
condition under which reads through an owner are plain loads
([`optimizations.md`](../optimizations.md#plain-loads-in-a-program-that-never-spawns)).

## M2. A function becomes four

A function given a table becomes:

- **A gate, under its own symbol, inlined into every caller.** It reads the
  function's state, and calls the plain copy once the function has stopped
  looking, or the lookup otherwise.
- **The lookup, which is never inlined.** It hashes the arguments' words and
  probes one entry of the table. On a hit it returns the remembered result.
  On a miss it runs the body copy and writes the entry over.
- **The body copy, the function as written.** Its calls back into the cycle
  go through the gates again.
- **The plain copy.** Its calls into the cycle go straight to the other
  plain copies, so it runs as the function did before.

The table is direct-mapped and holds at most 64 KiB per function. Each entry
is a tag, the argument words, the result words, and the work the result
took. A miss writes over whatever entry was there.

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
- **A hit subtracts the calls it saved.** A miss counts the calls with tables
  that ran while its result was computed, and keeps the count in the entry.
- **The score never goes below zero.**

Once the score reaches 128 calls, the function stops looking for the rest of
the run, and its gate sends every call to the plain copy. So a function whose
arguments rarely repeat, or whose repeats save less than its lookups cost,
pays for a bounded number of lookups and then runs as it would have.
Because the charge is relative, a function whose calls are heavy can look up
for a long time before its hits start to pay, as a search does before the
first position it reaches twice. One whose calls are light gives up after a
few dozen lookups.

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
