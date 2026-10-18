# Remediation plan for the 17 October 2026 audit

This plan proposes a fix for each of the 30 findings retained in
[`2026-10-17-report.md`](2026-10-17-report.md). The notebook behind it is
[`2026-10-17-working.md`](2026-10-17-working.md). The audited revision,
`41277c73`, is still `main` as this plan is written, so every location below
is the report's.

Each finding has its own entry: the **fix** and where it goes, the
**tests** that prove it and guard it, and the **docs** that change with it.
Every fix ships with its tests and docs in the same change. Three findings
call for a decision before they are built. The section "Decisions to make
first" lists them, each with a recommendation.

## Order of work

The findings are grouped into eight batches, each one a PR or a short
series of PRs. Test-gate fixes come first, so that the later batches,
which change the runtime and the backend, are checked by the stronger
gates.

| Batch | Findings | Why it goes here |
|---|---|---|
| 1. Test gates | F12, F26, F27, F28 | A crash must fail the rejection tests, and the unchecked drain branch must run, before anything below touches lowering or the runtime |
| 2. Small, independent fixes | F17, F18, F19, F29, F31 | Local fixes to the CLI and the tools, each with a direct test |
| 3. Entry point and backend ABI | F07, F08, F02, F13 | Programs and objects the compiler builds wrongly or crashes on |
| 4. Termination of semantics | F01, F14, F16 | Valid programs rejected, and checks that never finish. F16 needs a spec change |
| 5. Compile-time resource bounds | F09, F15, F05 | Allocation not bounded by the source program, and native memory never freed |
| 6. Runtime | F10, F11, F30 | Deadlock, physical memory held after use, and stdio in a fault handler |
| 7. Diagnostics rendering | F03, F04, F20 | One rework of `render.ml` |
| 8. Architecture | F22, F25, F23, F21, F24 | Refactors with no change in behaviour, smallest first |

Batches 2 to 7 are independent of one another once batch 1 is in. In batch
8, F22 comes before F25, because the fixed point's dependency tracking
uses the shared traversals.

## Decisions to make first

1. **F16: which generic types are ill-formed.** *Decided:* reject them at
   the declaration. A type whose instance must hold an
   instance of the same declaration at a strictly larger argument, such as
   `Grow<T>` holding `Grow<Array<T, 2>>`, has infinitely many distinct
   instance types. A compiler that writes out every instance with its own
   layout, as this one does, cannot finish such a type. Boxing cannot fix
   that. The other compilers that write out every instance refuse it too.
   C++ and Rust do so where the type is used, after a depth limit. Go
   recognizes the pattern itself and reports an "instantiation cycle"
   without counting. The check here follows Go's approach and makes it at
   the declaration, for three reasons:
   - The error reaches the author of the type, not whoever imports the
     package that declares it.
   - It names the member that makes the argument grow.
   - It depends on no limit.

   Generic verbs keep the depth limit (F01). A call in a generic body
   resolves per instance (D12), so a verb's growth is not visible in its
   declaration the way a type's members are. This is a language rule, so
   it belongs in the spec (`adt.md` §4, cross-referenced from
   `generics.md`): "a type whose definition, along any of its members,
   leads back to its own declaration at type arguments that strictly
   contain its parameters is ill-formed". The compiler change follows the
   spec PR. One question is still open: whether the rule follows all
   members or only owning ones (see F16).
2. **F08: how aggregates cross a call.** *Decided:* an aggregate travels
   in registers when it needs at most as many as the target's C calling
   convention gives one, and by address otherwise. That is 2 registers on
   x86-64 Linux and macOS and on AArch64, and 1 on x86-64 Windows. Packing
   small aggregates into whole words is a separate step, kept only if it
   measures faster (see F08).
   - **Why by address.** LLVM splits an aggregate held as one value into a
     piece per element and cannot select more than 65,535 pieces. Long
     before that limit, a large value is copied piece by piece at every
     call. Clang, rustc and swiftc never hand LLVM a large aggregate as
     one value. They pass it by pointer and return it through a pointer
     to the caller's storage. They keep a small one in registers: up to
     16 bytes (2 registers) in C on x86-64 Linux, macOS and AArch64, up to
     8 bytes on x86-64 Windows, and about two to four registers in Rust
     and Swift.
   - **Why count registers.** Registers are what a call spends. LLVM gives
     each element of an unpacked aggregate its own register, so the count
     is the number of pieces, not the size in bytes:
     `{ I32; I32; I32; I32; }` is 16 bytes but 4 registers.
   - **Why not by address for everything.** A small value passed in
     registers never touches memory. By pointer, it is stored and loaded
     again on every call that is not inlined.
   - **Why the meaning is kept.** A value parameter is a borrow (spec
     `memory.md` §2.9), and nothing else in the call writes what it
     borrows (§2.9.1). So passing the address keeps the language's
     meaning, and the parameter can tell LLVM so with `readonly` and
     `noalias`.
   - **Backstop.** The existing limit, extended to signatures, stays as an
     internal check that should never fire.
3. **F11: what happens to a drained chunk.** *Decided:* a few spare
   chunks stay warm. Every other spare keeps its addresses but gives its
   physical memory back to the system. Each drained chunk is kept as a
   spare for reuse. That avoids mapping it afresh, and while its pages
   stay resident it also avoids the page faults of touching new memory.
   But keeping every spare resident holds a program's peak memory for the
   rest of its run: 130 MiB in the audit's probe.
   - **The trade-off.** Giving pages back costs a fault per page when the
     chunk is reused. A program that builds and drops a large structure
     in a loop would pay that every round if every chunk went back at
     once.
   - **What others do.** The usual allocators settle it the same way:
     jemalloc returns unused memory over a decay period of about 10
     seconds, mimalloc after a short delay, and glibc's `malloc` trims
     above a threshold.
   - **What is chosen.** Warm spares cover immediate reuse, and the rest
     is returned at once. A delay before returning it is added only if
     the benchmarks show the faults (see F11). Nothing documents a reason
     for keeping every spare resident: the spare list came with #217, to
     make reuse fast, and returning memory was simply not part of that
     change.

## Batch 1: test gates

### F12: rejection tests accept crashes

**Fix.** In `tests/parser/syntax_test.py`, `assert_rejects` requires
`returncode == 1` (the exit status for "the compiler refused the program",
`bin/zanec/zanec.ml`) and a non-empty stderr. Exit 3, a negative status
(a signal) and any other status fail with the full output.

**Tests.** The change is to a test. Run the whole suite once with the
stricter assertion. Any case that now fails is a real crash: fix it in the
same PR, or file it and fix it before the PR merges.

### F26: generated-program suites force checking mode

**Fix.** Run every program in both modes.
- `tests/gen/gen_rules.ml` emits each run rule twice, once under
  `(setenv ZANE_CHECK 1 ...)` and once under `(setenv ZANE_CHECK 0 ...)`,
  both held to the same golden output. Remove the directory-wide `env`
  stanzas in `tests/codegen/dune` and `tests/objects/dune`, so that the
  mode is set per rule and not inherited.
- `dev/bin/check-programs` loops over `ZANE_CHECK` in `0 1`, and reports
  which mode failed.

**Tests.** The rules this generates are the tests. Confirm that the inline
drain branch in `lib/codegen/emit.ml` (`drain_scope`, the `plain` path)
now runs, with a fixture whose scope drains with no tasks and no mappings
(most fixtures do) under `ZANE_CHECK=0`.

**Docs.** Update the comments in the two `dune` files and
`tests/codegen/README.md` to say that every program runs checked and
unchecked.

### F27: memory probes are outside the gates

**Fix.**
- `tests/memory-probes/run` gains `--check`. It writes each `NAME.out` to
  a temporary directory, diffs it against the committed one, and exits
  non-zero on any difference. Without `--check` it keeps rewriting the
  committed outputs, as it does now.
- A probe whose output contains `== build failed` or
  `== the optimized build differs` fails `--check` unless its directory
  holds an `EXPECTED` file that names that outcome and says why.
- `just test-compiler` and the CI job that runs it call
  `tests/memory-probes/run --check` after `dune build`. Before the gate is
  enabled, run it twice in a row to confirm that no probe prints anything
  nondeterministic (addresses, timings). Make any such probe
  deterministic.

**Docs.** In `docs/memory-semantics-findings.md`, the sentence "The probes
are not part of `dune runtest`" becomes how they are gated, and the
justfile comment for `test-compiler` names them.

### F28: a fixture without a golden is silently untested

**Fix.** `tests/gen/gen_rules.ml` lists `fixtures/` as well as `golden/`
for each suite and fails, naming the file, when:
- a fixture has no golden file, or
- a golden file names a fixture that does not exist.

A fixture that is meant to be skipped has no reason to exist, so there is
no opt-out.

**Tests.** A unit test runs the generator's pairing function over a small
in-memory listing that has an orphan fixture and an orphan golden, and
checks both errors.

**Docs.** `tests/codegen/README.md` states the pairing rule.

## Batch 2: small, independent fixes

### F17: rewriting deletes a file it did not create

**Fix.** In `run_rewrite` (`bin/zanec/zanec.ml`), record that the
temporary file was created (set a flag as the first action inside the
`with_open_gen` callback) and remove it in the handler only when the flag
is set. If exclusive creation fails because the name exists, draw a new
random name and retry a bounded number of times (8) before reporting the
error.

**Tests.** Move the choice of temporary name into a function that takes
the random source, so a test can fix it. Add a unit test
that pre-creates a file at the first name the fixed seed gives, runs the
rewrite, and checks that the file survives and the output is written
under the next name.

### F18: `--stamp` accepts malformed stamps

**Fix.** Validate the value in both places:
- `bin/zanec/zanec.ml`: the `--stamp` case checks the value with
  `Rewrite.is_stamp` and gives `usage ()` otherwise, as `package_id` does.
- `Driver.with_stamps` (`lib/driver/driver.ml`): any other caller of the
  library gets an invocation diagnostic: "`garbage` is not a stamp".

**Tests.** Add a CLI test: `--stamp largeparam=garbage` exits 2 and emits
no object. Add a driver unit test for the diagnostic.

### F19: ambiguity-search timeouts accept NaN and infinity

**Fix.**
- `tools/ambiguity/profiles.py` `parse_duration`: reject a result that is
  not `math.isfinite(seconds)`. Check each part as well as the sum, since
  `'9' * 400` overflows inside one part.
- `tools/ambiguity/engine/config.ml`: the `--timeout` check becomes
  `Float.is_finite value && value >= 0.`, worded like the
  `max_frontier_ratio` check beside it.

**Tests.** Add cases to `tests/ambiguity/profiles_test.py` for `nan`,
`inf`, `float('nan')` and `'9' * 400`. Add an engine CLI test for
`--timeout nan` and `--timeout inf`.

### F29: duplicated regex assignment

**Fix.** Delete the second `DURATION_PART = ...` line in
`tools/ambiguity/profiles.py`. This goes in the same PR as F19.

### F31: explicit package options reject Unicode names

**Fix.** Package names on the command line follow the same lexical rule
as source identifiers (spec `lexical.md` §3, §4), so classify them with
the lexer itself and not with an ASCII copy of its rule.
- The grammar generator (`tools/grammar`) emits, beside the token rules in
  `lib/cst/lexer.ml`, a function `is_lower_identifier : string -> bool`.
  It runs the `LIDENT` regular expression on the whole string, and fails
  on leftover input and on keywords. Generating it from the same source
  keeps the two from drifting.
- `is_package_name` in `bin/zanec/zanec.ml` becomes that function. The
  `--import` key check uses it too.

**Tests.** Add CLI tests for `--check --package bücher=DIR`,
`--import app:bücher=bücher` and a `_`-private Unicode name. Keep the
negative cases: an uppercase first letter (ASCII and `Ü`), a leading
digit, and an empty name.

**Docs.** No change: the CLI help already says "a package name".

## Batch 3: entry point and backend ABI

### F07: an aggregate-returning `main` gets the wrong entry signature

**Fix.** The runtime calls `void zane_main(void)`, so the entry must always
have that type. In `lib/cgt/program.ml`, always emit the `zane.start`
wrapper as the entry: it makes the constants (there may be none) and then
calls `main` as a `Stat.Eval`, which discards the result. The
`if constants = [] then finish (Some entry)` shortcut goes away, so the
entry ABI no longer depends on whether the package has constants. An
optimized build inlines the wrapper. In an unoptimized build it costs one
call.

Check in the same change that discarding a result which owns blocks
(`String`, `List`, a `#struct`) leaves them in the program's region,
which "goes with the program" (`runtime/main.c`), and that the drain check
after `zane_main` still holds.

**Tests.** Add codegen fixtures whose `main` returns `Array<I64, 10>`,
`String`, a `#struct` owning a list, and `Unit`, each with and without an
unused package constant. All exit 0 with the same output in both checking
modes (batch 1 makes that automatic).

**Docs.** `docs/design/lowering.md` L16: the entry is always the start
function, and why.

### F08: the large-aggregate guard misses parameters

**Fix** (decision 2). Aggregates above a threshold cross calls by
address.
- **Signature rule.** Set it in one place, a function in
  `lib/codegen/emit.ml` beside `fn_type`.
  - **Counting.** A parameter or result is counted in registers: the
    number of scalar pieces its CGT type lowers to. `Struct` and `Sum`
    count their members, with the tag and each payload word one apiece,
    and `Array (t, n)` counts `n` times `t`. `Void` counts nothing. Use
    the CGT type, not LLVM's, so the rule cannot depend on `data_layout`.
  - **The limit.** A value of more than `registers` pieces is passed as a
    `ptr`. `registers` comes from the target triple: 1 for
    `x86_64-*-windows-*` and 2 otherwise, since F02 limits the targets to
    64-bit ones. Results use the same count.
  - **Cost.** The decision is made per signature while compiling, so the
    generated code has no branch at run time: each call site passes
    either way, fixed by its type. Counting is a walk over the type,
    cached per type like its layout.
  - **What crosses.** Every scalar and every one-member struct (L5)
    still passes as itself. A string or list handle (three pieces) goes
    by address. The 65,536-element array, the crashing case, goes by
    address too.
- **Packing, as a measured step.** After the rule above is in and
  measured, try packing small aggregates into 8-byte words before a call
  and unpacking them in the callee, as clang does.
  - **What it changes.** The count becomes the number of words:
    `{ I8; I8; I8; }` then needs 1 register and `{ I32; I32; I32; I32; }`
    needs 2, so both travel in registers instead of by address.
  - **What it costs.** A few instructions to combine and split fields
    around each call.
  - **The decision.** Keep it only if the benchmark below is faster with
    it on some target and slower on none. Treat every word as an integer
    register; following the platform's separate floating-point registers
    is a further variant to measure only if packing is kept.
- **Measuring.** On each first-tier target, run three builds of the spec
  repo's `langbench/` programs and the binarytrees reference
  (`docs/design/binarytrees-reference-results.json`), optimized and
  unoptimized: the current compiler, the register rule, and the rule
  with packing.
  - **An added benchmark.** Non-inlined calls on a 16-byte two-field
    struct, a three-byte struct, a string handle and a variant with a
    64-byte payload.
  - **Expected result.** The register rule is no slower than the current
    compiler. If a benchmark is slower, find out why before changing the
    limit.
  - **Recording it.** Put the table in `docs/design/lowering.md` §9
    beside the rule.
  - **Where to run.** On the maintainer's machine, since timings from a
    container are not comparable.
- **Telling LLVM what the spec guarantees.** A by-address value parameter
  carries `readonly` and `noalias`, and its alignment and
  `dereferenceable` size. Nothing in the call writes what it borrows
  (`memory.md` §2.9.1), so the optimizer may treat the pointed-to value as
  a private copy. Leave `nocapture` off: a call spawned inside the callee
  can hold the address for as long as it runs. An `sret` result carries
  `noalias` and its alignment as well.
- **Parameters.** When the argument is a place, the caller passes its
  address. Nothing in the call writes what it borrows (`memory.md`
  §2.9.1), so no copy is needed. Any other argument is built in a fresh
  slot in the caller's frame, and the caller passes that slot's address.
  The callee uses the pointer as the parameter's slot and does not store
  a whole value into an `alloca`.
- **Results.** The callee writes the result through a leading `sret`
  pointer to a slot in the caller's frame.
- **Function values** (`Call_value`, L14) use the same rule, since it
  depends only on the type.
- **Backstop.** The final scan in `Big_moves.rewrite` also checks each
  defined and declared function's parameter types and return type, and
  reports a broken invariant (`Diagnostic.bug`), not a user error, if one
  is still too large.

Separate compilation is unaffected beyond this. The rule is a function of
the type and the target, and objects for different targets never link, so
every object a program links agrees on it.

**Tests.**
- **The crash.** Add a library fixture with `consume(x Array<I64, 65536>)`
  built with `--object` (exits 0).
- **Every kind of call.** Add a program that passes and returns
  `Array<I64, 65536>` through ordinary calls, a function value and a
  spawned call, then checks the contents.
- **Both sides of the limit.** Add a program that passes and returns
  values of one, two and three pieces, as a struct and as a variant, so
  both conventions run in every build mode. Run it for
  `x86_64-windows-gnu` too, where the line falls between one and two.
- **The count.** Add a unit test of the counting function on each CGT type
  form.
- **The attributes.** Add a `--ll` check that a by-address parameter
  carries the attributes above.
- **The backstop.** Add a unit test that the backstop fires on a
  hand-built module.

**Docs.** `docs/design/lowering.md` §9 (large aggregates): the register
count, the limit per target, the by-address convention, the attributes
and why they hold, whether packing was kept, and the measurements behind
both.

### F02: 32-bit and other unsupported layouts are accepted

**Fix.** CGT and the runtime assume 8-byte pointers and 8-byte alignment
for `i64` and `double`. In `Build.target_machine`
(`lib/codegen/build.ml`), after the target machine is created, read its
data layout and refuse the target unless:
- the pointer size is 8,
- the ABI alignment of `i64` and `double` is 8.

The error is an invocation diagnostic: "the target `i386-unknown-linux-gnu`
has 4-byte pointers; this compiler builds for 64-bit targets only". While
implementing this, check whether anything relies on little-endian byte
order (constant folding of text, the object rewriters in `lib/rewrite`).
If something does, add byte order to the check.

**Tests.** Add CLI tests: `--ll --target i386-unknown-linux-gnu` and
`--target armv7-unknown-linux-gnueabihf` exit 2 with the message, and
`x86_64-windows-gnu`, `aarch64-apple-darwin` and `x86_64-linux-gnu` are
still accepted.

**Docs.** `docs/design/platforms.md` gains a short section that names the
64-bit requirement and the data-layout facts it rests on.

### F13: huge array lengths truncate and overflow

**Fix.** Use one size limit, and checked arithmetic everywhere up to it.
- **Limit.** A type whose size is `2^48` bytes or more is a compile-time
  error. No such value can be placed, since the runtime's chunk map covers
  48-bit addresses (`docs/design/platforms.md`, "Address range").
- **Checked arithmetic.** `Nodes.Ty.size_align` (`lib/cgt/nodes.ml`),
  `Type_layout.stride` and `Frames.layout` use addition and multiplication
  that fail on overflow and on reaching the limit. The failure becomes a
  lowering `Refused` diagnostic at the span of the declaration or use that
  names the type: "`Array<I64, 4294967296>` takes 32 GiB, which the
  `--fixed-region` cannot hold" when it exceeds the region, and "takes
  more than 2^48 bytes" past the limit. Frames already check for frames
  larger than the guard at run time. This adds a compile-time check
  against the fixed-region size actually in force, so that the user gets
  a diagnostic and not a runtime stop.
- **LLVM's 32-bit counts.** Add stubs in `lib/codegen/llvm_stubs.c` for
  `LLVMArrayType2` and `LLVMGetArrayLength2`, both 64-bit. Use them in
  `Emit.lltype` and `Big_moves.parts` in place of `Llvm.array_type` and
  `Llvm.array_length`, which truncate to 32 bits. `parts` multiplies
  lengths too, so it uses checked arithmetic and saturates at
  `most_parts + 1`.

**Tests.** Add rejection fixtures for `Array<I64, 4294967296>` (larger
than the region), `Array<I64, 1152921504606846976>` (`2^60`, past the
limit) and a nested `Array<Array<I64, 65536>, 65536>`. Add a library
fixture with `Array<I8, 4294967297>` behind a reference, to show that
the LLVM type now has the full count; its IR line is checked with
`--ll | grep`. Add a unit test for the checked `size_align`.

**Docs.** `docs/design/lowering.md` §9 and `platforms.md`: the size limit.

## Batch 4: termination of semantics

### F01: the instantiation limit counts unrelated uses

**Fix.** Count instances along the chain of instantiations that led to
each one, not across the build.
- `Env.pending` (`lib/tst/model/env.ml`) gains `p_chain : int list`, the
  declaration ids of the instances being checked when this one was
  requested, innermost first. `Env.t` gains `current_chain : int list ref`,
  set by the loop in `Tst.Check.Program.run` (`lib/tst/check/program.ml`)
  around `check_body` and empty while non-generic bodies are checked.
- `Instances.request` counts how often `id` occurs in
  `id :: !(env.current_chain)`, and reports when that count passes
  `instance_limit`. The existing message ("its calls to itself never reach
  a fixed set") is then true. Add the first few links of the chain to the
  message, so the user sees the cycle.
- `instance_counts` remains only as the "was this declaration ever
  instantiated" set that `program.ml` reads (`instantiated`). Rename it to
  `instantiated` and make it a `(int, unit) Hashtbl.t`.

`instance_keys` already dedupes argument sets, so a chain that revisits a
finite set of instances never grows. Only a chain of ever-new argument
sets reaches the limit, and that is the case the diagnostic describes.

**Tests.** Add a semantics fixture: the audit's 65 distinct one-field types
through a non-recursive `consume(x T Type)` is accepted. Use 200 types, so
the test does not sit right at the boundary. Keep or add the rejection
golden for `f<T>` calling `f<Pair<T>>`, now showing the chain.

**Docs.** `docs/design/semantics.md` D12: the limit is on a chain's
depth.

### F14: exhaustiveness enumerates the whole case space

**Fix.** Each arm covers exactly one combination of cases (there are no
wildcards and no default, adt.md §5), so coverage can be counted without
enumeration.
- **Total.** The product of each scrutinee's case count, computed with
  saturation at `max_int`.
- **Covered.** The number of distinct keys in `covered` whose every case
  is valid for its scrutinee. Invalid ones were already reported.
- **Missing.** `missing = total - covered`. When it is positive, find up
  to three examples by walking the combinations lazily (a `Seq`) in
  lexicographic order and skipping covered keys. The walk stops after at
  most `covered + 3` steps, which is bounded by the number of arms.
- **Message.** "(and N more)" uses `missing - 3`. When the total
  saturated, say "and more than N" with `N = max_int - covered`.

**Tests.** Add a semantics golden for a match on 30 two-case enums with one
arm. It must finish quickly; add a timeout on the rule if dune allows one,
or keep the fixture small enough to fail loudly when it regresses. Run the
existing exhaustiveness goldens unchanged, including the three-example
order.

### F16: expanding generic types never finish

**Fix** (decision 1: rejected at the declaration). The rule lands in the
spec first, then:
- **Semantic check.** After type definitions resolve, `Type_decls` runs a
  new check, `check_expanding_types`, over a graph whose nodes are the
  type parameters of generic declarations.
  - **Edges.** For each occurrence of `B<args>` in `A`'s definition (struct
    and variant members, a distinct type's right side, and element types
    of `Array`, `ArrayRef` and `List`), there is an edge from each
    parameter `T` of `A` to each parameter `U` of `B` whose argument
    mentions `T`.
  - **Expanding edges.** The edge is **expanding** when `T` occurs strictly
    inside that argument (`T` inside `Array<T, 2>`), and **plain** when the
    argument is `T` itself.
  - **The error.** A cycle in this graph that contains an expanding edge is
    an error at the declaration, naming the member that closes the cycle.
    Following parameters rather than declarations catches growth that
    passes through another type: `A<T>` holds `B<Array<T, 2>>`, and `B<U>`
    holds `A<U>`.
  - **Cost.** The check is strongly connected components over the
    parameter graph, linear in its size.

  It follows the approach of Go's "instantiation cycle" check. Before
  implementing it, confirm what Go rejects for types (as opposed to
  functions), and add any case Go catches that this graph misses.
- **Which members.** Decide in the spec PR whether `&` members count. A
  reference is a fixed-size pointer and is never walked, so excluding them
  is sound if no other stage instantiates a referenced type's layout. The
  implementation must confirm that before the spec excludes them.
- **Backstop.** `Type_layout.boxed` and `positions`
  (`lib/cgt/type_layout.ml`) carry a depth and call `Diagnostic.bug` past
  a generous bound (say 10,000), so that a missed case is an internal
  error and not a hang or a stack overflow.

**Tests.** Add a rejection golden for the audit's
`Grow<T> = variant { done Unit; more Grow<Array<T, 2>>; }`, and one for an
expansion through a second declaration (`A<T>` holds `B<T>`, which holds
`A<List<T>>`). Ordinary recursion (`Tree<T>` holding `Tree<T>`) and
mutual recursion at the same arguments are still accepted, with their
existing fixtures.

**Docs.** The spec PR (`adt.md` §4, `generics.md`). Then
`docs/design/semantics.md`: the new check, and that boxing still decides
per instance.

## Batch 5: compile-time resource bounds

### F09: memo replay bypasses the evaluator's budget

**Fix.** Charge outputs as they are made and when they are replayed, and
cap them in total.
- `run` (`lib/optimize/eval.ml`) gains `mutable output_bytes : int` and
  `mutable output_count : int`.
- `Print` charges the text's length through the existing `bytes`
  function, and adds the length and one entry to the two counters.
- A memo entry stores its output list together with that list's count and
  bytes, computed once when it is recorded. Replay charges both through
  `bytes` before the `rev_append`, so a replay costs what producing the
  output cost.
- When `output_bytes` exceeds `Materialize.max_size` (the most a folded
  result may materialize to), the run stops with
  `stop "output too large to fold"`. The fold then falls back to the
  running program, as it does for any other stop.
- A call whose output exceeds the same cap is not memoized, so the memo
  table's size is bounded by the step budget.

**Tests.** Add an optimizer unit test: a function that calls its previous
level twice and prints once at the base, 40 levels deep, folds or stops
quickly under a small heap limit, and the optimized program's output
matches the unoptimized one. Add a codegen fixture with the same program
at a size that runs, both builds held to one golden.

**Docs.** `docs/design/optimization.md` O6: outputs are charged, replay
included, and capped.

### F15: array ownership metadata grows with the array's length

**Fix.** Describe an array of owning elements once, not once per element.
- `Layout.kind` (`lib/cgt/nodes.ml`) gains
  `Array of { count : int; stride : int; elements : Layout.t }`, the same
  shape `List` has.
- `Type_layout.positions` emits one `Array` position in place of
  `List.init n`.
- `lib/codegen/walks.ml` emits a loop over `count` for an `Array`
  position, as it already does for a list's elements, and does not unroll
  it.
- The constant evaluator (`lib/optimize`), which reads `layouts`, treats
  the new kind like a list of fixed count.

**Tests.** Every existing fixture with an array of strings or lists passes
unchanged in both checking modes. Add a fixture with
`Array<String, 100000>` that fills, copies, moves and drops the array,
then prints a checksum. Add a unit test that the positions of that type
are one entry.

**Docs.** `docs/design/lowering.md` §9: positions of an array.

### F05: LLVM contexts and modules are never disposed

**Fix.** Make the module's lifetime a scope.
- `Codegen` exposes `with_program : ... -> (Llvm.llmodule -> 'a) -> 'a`.
  It creates the context and the module, runs the function, and disposes
  both in `Fun.protect ~finally`. `Emit.program`'s own failure paths go
  through it too.
- `Driver.ir`, `executable` and `object_file` (`lib/driver/driver.ml`) use
  it. `ir` copies the module's text to an OCaml string before the scope
  ends, as `string_of_llmodule` already does.
- `Codegen.emit` stops returning a raw module. Nothing outside `Codegen`
  holds one past the scope.

**Tests.** Add a unit test with a test-only counter of live contexts in
`Codegen`, incremented on create and decremented on dispose. It is zero
after a successful `Driver.object_file`, after one that fails in
`prepare` (an unknown target), and after one that raises.

## Batch 6: runtime

### F10: a constant cycle across contexts deadlocks

**Fix.** Detect cycles in a wait-for graph when a context blocks.
- Each `zane_context` gains a `waiting_for` field: the context it is
  blocked on, or none. The edge comes from one of two waits:
  - **Constant.** The maker of the constant it is waiting for (state
    `s` gives maker id `s - 1`).
  - **Join.** The context running the task it is joining
    (`zane_join_task`, when the task was taken elsewhere).
- A registry from context id to context makes the maker reachable. It
  holds every context ever created, since contexts are reused, never
  freed.
- Both waits take a global `zane_waits` lock, only on the slow path where
  they are about to block. Under it a context sets its `waiting_for`,
  follows the chain from that context, and on reaching itself calls
  `zane_broken("package constants read each other while they are made")`.
  It clears the edge when it wakes.
- The existing same-context check (`s == self`) stays as the one-step
  case of this test.

**Tests.** Add a runtime C test that reproduces the audit's probe: two
contexts, each begins its own constant, a barrier, then each begins the
other's. It must stop with the message within the test's timeout and not
hang. Add a second test that closes the cycle through a join. If a Zane
program can reach either shape (a constant whose initializer spawns a
call that reads another constant, which reads the first), add it as a
codegen fixture with expected status and stderr.

**Docs.** `docs/design/lowering.md` L16: cycles are detected across
contexts.

### F11: spare chunks are cached without bound

**Fix** (decision 3). A spare chunk is **warm** (its pages resident) or
**cold** (addresses kept, physical memory given back).
- **Chunks come from the system directly.** Today a chunk comes from
  `aligned_alloc`, or `_aligned_malloc` on Windows (`zane_internal.h`).
  Memory from the C allocator cannot be decommitted on Windows, and on
  POSIX the runtime would be giving back pages inside memory `malloc`
  owns. So a chunk is taken with the helpers `runtime/region.c` already
  has for the fixed-size range: `zane_reserve_aligned`, then
  `zane_commit_range`, and given back with `zane_release_addresses`.
  - **Windows.** There a 1 MiB-aligned reservation costs an extra MiB of
    reserved addresses. Take chunks by carving them from larger aligned
    reservations, 64 MiB at a time, so neither the waste nor the system
    calls are per chunk.
  - **Oversized blocks** (more than one chunk) take the same route.
- **Warm spares.** `zane_unmap` (`runtime/arena.c`) keeps a drained chunk
  warm while its context holds fewer than `ZANE_WARM_KEPT` (4) warm
  spares. `zane_give_spares` (`runtime/snapshot.c`) moves a context's warm
  spares to the global pool, which keeps at most `ZANE_POOL_WARM` (16)
  warm.
- **Cold spares.** Every other drained chunk turns cold. Its pages after
  the first are given back: `madvise(MADV_DONTNEED)` on Linux and macOS,
  and `VirtualFree(MEM_DECOMMIT)` on Windows. The first page holds the
  chunk's `zane_mapping` header and the link of the spare list, so it
  stays.
  - **Reuse.** A cold chunk is reused like a warm one: its pages fault
    back in, zeroed, on first touch. On Windows it is committed again
    first, through `zane_commit_range`, and a failed commit stops the
    program the way any failed commit does.
  - **The limit.** Past `ZANE_COLD_KEPT` cold chunks (256, which holds
    1 MiB of first pages), a drained chunk is released entirely.
- **Reuse order.** `zane_map` prefers a warm spare, then a cold one, then
  a new chunk.
- **Counts.** A per-context warm count, and warm and cold counts for the
  pool, are kept beside the lists, so every limit is O(1).
- **A delay, as a measured step.** Measure the change above with the
  binarytrees reference (`docs/design/binarytrees-reference-results.json`),
  the memory bench and the spec repo's `langbench/`, before and after, on
  the maintainer's machine.
  - **When to add it.** Only if returning pages at once is slower there.
  - **What it is.** Chunks turn cold only after sitting unused for a
    while: past a number of later drains of the same context, so no
    timer thread is needed. Choose that number from the same
    benchmarks.

**Tests.**
- **The audit's probe.** Add a runtime C test: record resident memory
  (`/proc/self/statm` on Linux, where the tests run), allocate 128 chunks
  in a scope and fill them, drain the scope, and let the context go idle.
  Resident memory must fall back to within a few MiB of where it started,
  where it stayed at 130 MiB before.
- **The counts.** Through an internal counter exposed to tests in
  `zane_internal.h`, at most 4 chunks stay warm on the context and at most
  16 in the pool.
- **Reuse.** A second test allocates 128 chunks again after the drain and
  checks that the cold chunks are reused (counted), that they read as
  zero, and that the output matches.
- **Existing tests.** Run the existing runtime tests and codegen fixtures
  in both checking modes, and the Windows programs check, since Windows
  takes the decommit path.

**Docs.** `docs/design/lowering.md` §9 (regions and chunks): warm and cold
spares, where chunks come from, what each platform does to give pages
back, and whether a delay was kept, with the measurements.

### F30: overflow handlers call stdio

**Fix.** Make the program's output buffer the runtime's own, so that the
fault handler can flush it with only async-signal-safe calls.
- **Buffer.** `runtime/block.c`'s print writes into a runtime buffer
  (64 KiB) instead of `stdout`. The buffer is guarded by a mutex for
  ordinary writers, plus an atomic `busy` flag that a writer sets while it
  holds the buffer.
- **Flush.** The buffer is flushed with `write(1, ...)` in a loop
  (`WriteFile` on Windows), and a failed write records an error flag.
- **Normal paths.** The exit path in `runtime/main.c` flushes the buffer
  and tests the error flag in place of `fflush(stdout)` and `ferror`. So
  do `zane_broken` and the index-out-of-range path.
- **Fault path.** `zane_stop` with `flush_stdout` claims the buffer with
  an atomic compare-and-swap on `busy`. If it gets it, it writes the
  buffered bytes with `write(1)`. If another thread holds it, or the
  faulting thread was itself mid-print, it skips the flush and loses at
  most that buffer. It never blocks. The commit-failure path can then
  flush the same way, which it does not do now.
- **Remaining stdio.** Nothing else in the runtime writes to `stdout`.
  `fprintf(stderr, ...)` calls outside the handler stay.

**Tests.** The existing "recursion too deep" and "scopes nested too deep"
fixtures still show the output printed before the error. Add a runtime C
test that overflows the stack in one thread while another prints in a
loop; it must exit 1 with the message, not hang, across many runs under
the test's timeout. Add a test that a write error on stdout (stdout
closed or a full pipe) still gives exit 1.

**Docs.** `docs/design/lowering.md` §9 and `platforms.md` ("Machine stack
sizes"): the buffer, and what the fault handler flushes.

## Batch 7: diagnostics rendering

F03, F04 and F20 all change how `lib/diagnostic/render.ml` turns a source
line into a displayed one, so they land together.

**Fix.** Build the displayed line once, as a sequence of (bytes shown,
cell width) per source character, and derive both rows from it:
- **Control characters (F20).** C0 controls other than tab, DEL, C1
  controls (U+0080 to U+009F) and the bidirectional controls (U+202A to
  U+202E, U+2066 to U+2069) are shown as visible escapes such as `\x1b`
  and `‮`, each as wide as its escape text. Tabs expand as now. The
  file name in every location form (`at_span`, and the file and directory
  cases of `render`) is escaped the same way. So is any source text quoted
  in a message: escape when rendering, not where messages are made.
- **Widths (F03).** A character's cell width is 0 for combining marks, 2
  for wide East Asian characters and emoji, 1 otherwise. Add `uucp` as a
  dependency (`zane-compiler.opam`, `devbox.json`) and use
  `Uucp.Break.tty_width_hint`, which is built for this. Invalid UTF-8
  bytes are escaped like controls.
- **Gutter (F04).** The caret row's gutter is spaces as wide as the line
  number, then ` | `, so it lines up for any number of digits.
- **Header.** The `characters N-M` header keeps counting characters (code
  points), not cells, so editor jump-to-column is unchanged.

**Tests.** Add parser rejection goldens with an error after `é` written as
`e` plus a combining mark, after a CJK string literal, after an emoji,
on line 10 and on line 100. Add a source line holding `ESC [ 2 J` inside a
string literal before an error. Add a file name holding a control
character. Read every existing golden's diff by eye; only the cases above
should move.

**Docs.** The comment at the top of `render.ml`.

## Batch 8: architecture

These change structure, not behaviour. Each PR must leave every golden,
fixture and generated rule unchanged. CI's file-size check
(`just check-file-sizes`) is the bar for the new modules.

### F22: traversals live in particular analyses

**Fix.**
- Move TST `parts` and `stat_exprs` from `lib/tst/analyses/exits.ml` to a
  new `lib/tst/model/traverse.ml`, exported from `tst.mli` under that
  name.
- Move CGT `parts`, `walk` and `map` from `lib/cgt/regions.ml` to
  `lib/cgt/traverse.ml`, exported from `cgt.ml`.
- `lib/optimize/fold.ml` drops its own child and body inventories and
  uses `Cgt.Traverse`.
- Each analysis keeps only what is specific to it.

**Tests.** Add a unit test per traverse module: on one node of each
constructor, `parts` returns exactly its children, so a new constructor
that the traversal misses fails a test, not an analysis.

### F25: fixed points rewalk every body, and repetitions are computed twice

**Fix.**
- Compute `Repeats` once in `Tst.Semantics.check` and pass it to
  `Read_only.run` and `Spawns.run`.
- Change `Fixpoint.settle` (`lib/tst/analyses/fixpoint.ml`) from
  "walk everything until nothing grows" to a worklist:
  - While walking a body, each read of another declaration's summary goes
    through `Fixpoint.read`, which records a dependency of the walked body
    on that declaration.
  - When a summary grows, only its readers are queued again.
  - The final `~report:true` pass over every body stays as it is.

**Tests.** Every semantics golden is unchanged. Add a unit test on a
synthetic chain of 2,000 calls ordered worst-first, which checks that the
number of body walks is linear (counted by a test hook), not quadratic.

### F23: ABI numbers are written twice

**Fix.** Write each number once and derive the rest.
- A new header, `runtime/zane_abi.h`, holds `#define`s for every offset,
  size and count that emitted code relies on: the record and task sizes,
  heap, context and handle offsets, and the class count.
  `zane_internal.h` includes it, and its static assertions compare the
  real `offsetof` and `sizeof` with these macros.
- A dune rule reads `zane_abi.h` (plain `#define NAME number` lines,
  parsed without a C compiler) into a generated `lib/codegen/abi.ml`.
  `frames.ml`, `emit.ml` and `walks.ml` use `Abi.*` in place of their
  literals.
- The runtime tests compile a probe that prints every `offsetof` and
  `sizeof`. A unit test compares the probe's output with `Abi`, which
  catches a header that drifts from the structs on any platform the tests
  build for.

**Tests.** The probe comparison, plus the whole suite.

### F21: lowering is one 1,834-line recursive walk

**Fix.** Split `lib/cgt/lower.ml` by responsibility, keeping the recursion
in one small core:
- `lower.ml` keeps the expression, statement and block walk and the state
  record.
- The other responsibilities move to modules that take the walk as a
  function argument (`expr : state -> T.Expr.t -> Expr.t`), so they do not
  need to be in the recursive knot:
  - `lower_intrinsics.ml`: runtime intrinsics and operators.
  - `lower_data.ml`: arrays, strings, constructors and defaults.
  - `lower_match.ml`: match dispatch.
  - `lower_calls.ml`: ordinary, function-value and subscript calls.
  - `lower_spawn.ml`: spawn frames and handlers.
  - `lower_lambda.ml`: lambdas.
- Move one module per commit, each commit building and passing.

Aim for a core under 800 lines. No new module should approach the
file-size warning (1,500 lines).

**Tests.** The suite, unchanged, after each commit.

### F24: one mutable environment for every semantic phase

**Fix.** Give each phase a type that says what it may read and write. Do
it in stages, each of them a PR:
1. Group `Env.t`'s fields (`lib/tst/model/env.ml`) into sub-records by the
   pass that fills them:
   - `names`: Collect.
   - `types`: Type_decls (type infos, aliases, partially defined types).
   - `verbs`: Verb_signatures (overload registries, signatures).
   - `instances`: Program (generic queue, instance keys, current chain
     from F01, notes).
   - `counters`.
2. Each pass's entry point takes the sub-records it writes mutably, and a
   read-only view of the ones before it: a module signature with an
   abstract type and only accessors. `Semantics.check` threads them in
   order, replacing the readiness flags (`defining`, and the options that
   say a stage has run) with the presence of the earlier stage's result.
3. Deferred closures stored in the environment become explicit queues
   that their owning pass drains before it returns.

**Tests.** The suite, unchanged, after each stage.

## Done when

- Each finding's tests above are in and pass, in both checking modes
  where they run programs.
- `just test`, `just check-file-sizes`, the Windows programs check, and
  the new memory-probe gate all pass on the final head.
- The report's exact reproductions all now give the expected result: the
  audit's commands for F01, F02, F07, F08, F13, F16, F18 and F31, the
  runtime probe for F10 and the RSS probe for F11. Those for F07 and F08
  build and run cleanly; those for F02 and F18 give a diagnostic. Record
  each in an "Outcome" section appended to this file, finding by finding,
  with the commit that closed it.
