# Refactoring proposal

Status: **being carried out**, in the four steps of §12. Step 1 is done: DC1,
DC2, DC3, ST1, IF1's two deletions, IF2's five re-exports, SH1, TS2, IV1 to
IV5, and T4. Step 2 is done: IV6, TS1, SZ1 and SZ2. IV6 found that of the 21
"does not handle … yet" refusals only three can be reached by a program
semantics accepts, and that lowering alone checked a third rule, a literal's
range, which semantics now checks too. Step 3 has carried out SH3, DR1, DR2, ST2's first
step, ST2's second step for the analyses, ST3, ST4, SH2, L1 and L2.

This is the second strict review of the repository. The first one,
[`file-structure-proposal.md`](file-structure-proposal.md), was about where
files sit, and it has been carried out. This one is about the code inside the
files:

- files that have grown too large again;
- state the semantics stage keeps in globals;
- helpers that are written out more than once;
- how the compiler handles its own invariants when they break;
- the libraries' interfaces;
- the driver;
- the tests that have to guard all of this.

This proposal also does two other things:

- It checks, finding by finding, an outside review of the compiler written
  by another AI (§2).
- It takes over the items the file-structure proposal left open (§11), so
  one document tracks everything that is still to do.

Every number here was measured on commit `e40f959`. Every finding names the
path it is about, so it can be checked against the tree. The findings use
the same tags as the first proposal:

- **Must**: this is wrong now. A reference points nowhere, a message
  contradicts another, or a check is missing that the code relies on.
- **Should**: this is a real cost, and it gets worse as the compiler grows.
- **Nit**: consistency or tidiness. Cheap to fix, and it adds up.

## Contents

1. [Summary](#1-summary)
2. [The outside review, checked](#2-the-outside-review-checked)
3. [File size](#3-file-size)
4. [Semantics state](#4-semantics-state)
5. [Shared helpers](#5-shared-helpers)
6. [Invariants and internal errors](#6-invariants-and-internal-errors)
7. [Interfaces and entry modules](#7-interfaces-and-entry-modules)
8. [The driver](#8-the-driver)
9. [Tests](#9-tests)
10. [Docs](#10-docs)
11. [Carried over from the file-structure proposal](#11-carried-over-from-the-file-structure-proposal)
12. [Migration order](#12-migration-order)
13. [What should stay as it is](#13-what-should-stay-as-it-is)

---

## 1. Summary

The pipeline is still sound: CST → SST → TST → CGT → LLVM. Each stage has its
own library, and each library depends only on the ones below it. The problems
are inside the stages:

1. **`lib/cgt/lower.ml` has grown back past its old size.** G1 moved about
   500 lines out into `state.ml`, `type_layout.ml` and `literals.ml`. Even so,
   the file is now 1,946 lines, up from the 1,808 measured before that split.
   One banner, "Verbs", covers lines 23 to 1724. `lib/tst/check/check.ml` is
   1,747 lines, 250 more than T3 expected. In both files, a few hundred lines
   at the top or bottom are not part of the recursive walk and can move out.
2. **Semantics keeps its state in globals.** There are 38 module-level
   tables and references across 12 modules of `lib/tst/`. Each pass resets
   its own share. Four counters are reset by nothing, so a second
   `Tst.check` in the same process numbers declarations, locals and type
   parameters differently from the first.
3. **Broken invariants reach the user as uncaught OCaml exceptions.** There
   is no internal-error path:
   - `Option.get` on `None`, `Failure "codegen: …"` and
     `Invalid_argument "List.combine"` all end the compiler with a bare
     `Fatal error: exception …`.
   - Four places do the opposite and silently recover from a mismatch that
     cannot happen.
   - Lowering reports 27 of its own invariants to the user as if the
     program were at fault.
4. **One fact is written in several places.** A generic type's
   substitution is written eight times, with two different policies. The
   runtime's ABI is declared once in `runtime/zane.h` and again as a
   string-keyed table in `lib/codegen/emit.ml`. Small helpers (`quote`,
   `is_guest`, `strip`, `signature_of`) are written two to five times
   each.
5. **The interfaces are still missing (L1, L2).** Without `.mli` files, the
   compiler cannot see the two dead functions this review found by hand, or
   the five re-exports that nothing outside their library uses.
6. **The driver holds pipeline logic.** `bin/zanec/zanec.ml` knows how to
   find `main`, how to match stamps to packages, and how to render four
   different error types. `tools/inspect/span_dump.ml` repeats part of that.
7. **Nothing tests lowering's refusals.** It has 54 `refuse` sites, and no
   golden file contains any of their messages.

---

## 2. The outside review, checked

An AI review of the compiler found that the architecture is disciplined, and
then listed some technical debt. Each of its claims is checked below against
the tree.

| Claim | Verdict | Evidence | Handled in |
|---|---|---|---|
| The architecture is organized: a separate library per stage, TST split into `model/`, `passes/`, `check/` and `analyses/`, and tests split by suite. | **True.** | `lib/*/dune`. The dependency graph only points down. | §13 |
| `lib/cgt/lower.ml` (about 87 KB) and `lib/tst/check/check.ml` (about 78 KB) are large enough that they should be split. | **True, and understated.** | They are 87,332 bytes (1,946 lines) and 78,016 bytes (1,747 lines). `lower.ml` has *grown* since G1 split it. | SZ1, SZ2 |
| `docs/file-structure-proposal.md` says it is carried out except for some tasks, among them splitting the checker and lowering and adding `.mli` files. | **Mostly true.** | The header's list of open items matches the tree. One detail is off: the checker split (T3) is done, and for lowering only G1's sub-banners are open. The body still states pre-split sizes in the present tense. | DC3, §11 |
| The libraries expose their APIs inconsistently. | **True.** | L2 is unchanged: `Cst` and `Sst` `include To_tree_graph`, while `Tst` and `Cgt` bind `to_node` with a `let`. | IF2 |
| Several `Option.get`s assume an invariant that the code does not encode. | **True.** | There are 20 in `lib/`, and 13 of them are in `lib/codegen/emit.ml`. | IV3, IV4 |
| Semantics recovers silently from an invariant violation, e.g. `try List.combine … with Invalid_argument _ -> []`, or falls back to an unsubstituted type. | **True.** | `analyses/read_only.ml:89` and `:115`, `analyses/guests.ml:55`, `check/context.ml:107`. The same substitution is *unguarded* in four other places, which the review did not mention. | IV1 |
| There are a few `failwith`s and an `assert false`, mostly for "a previous stage guarantees this". | **True, and the gap is wider than stated.** | 7 `failwith`, 1 `assert false` and 5 `invalid_arg` in `lib/`. There are also 31 partial-function call sites in `emit.ml` alone. None of them reaches the user as an internal error. | IV2 |

---

## 3. File size

| # | Tag | Path | Finding | Proposal |
|---|---|---|---|---|
| SZ1 | Should | `lib/cgt/lower.ml` | The file is 1,946 lines with two banners: "Verbs" (lines 23–1724) and "Programs". It has three parts. **Lines 29–231** are 33 helpers that come before the `let rec`, so the walk does not reach them by recursion: verb symbols and keys (`symbol`, `key`, `verb_of`, `expands`, `by_address`, `value_verb`), outcomes (`outcome`, `plain`, `returned`, `done_`/`aborted`/`exited`, `outcome_case`, `outcome_layout`), and small CGT builders (`ptr`, `deref`, `local_ptr`, `unit_`, `arena`, `bind`). **Lines 232–1617** are the recursive walk, from `expr` to `place`. **Lines 1618–1946** are `func`, `made`, `name_lambdas`, `library_roots` and `program`, which call the walk and are not called by it. | Move the outcome helpers to `cgt/outcome.ml`, the verb helpers to `cgt/verbs.ml`, and the builders to `State` or a `cgt/build.ml`. Move lines 1618–1946 to `cgt/program.ml`, and point `Cgt.lower` at `Program.lower`. That leaves about 1,400 lines in `lower.ml`, all of them the walk. Inside the walk, add the sub-banners G1 asked for, along the groups the code already has: Expressions (`expr`); Primitives, lambdas and records; Storage, moves and borrows (`storage` … `lend`); Match, handlers and enum maps (`match_` … `case_place`); Subscripts and constructors (`subscript` … `arguments`); Spawns (`spawn` … `spawn_call`); Calls and expansion (`invoke`, `expand`, `block`, `code`); Statements and places. |
| SZ2 | Should | `lib/tst/check/check.ml` | T3 took out `context`, `instances`, `overloads` and `termination`, and estimated that about 1,500 lines would be left. 1,747 are. Lines 1467–1747 (`verb_body`, `check_body`, `typed_defaults`, `defaults`, `check_defaults`, `package_context`, `coerce_to`, `type_definition`, `declaration`, `run`) are pass 5's driver. They are plain `let`s after the recursive chain ends. The "Calls" section (lines 416–989, 573 lines) is the largest in the file, and it has no sub-banners. | Move lines 1467–1747 to `check/program.ml`, mirroring SZ1, and have `semantics.ml` call `Program.run`. Inside "Calls", add sub-banners for function calls, method calls, constructor calls, and arguments. |
| SZ3 | Nit | `tools/ambiguity/engine/search.ml` | `unified_search` (243 lines) and `parallel_unified_search` (237 lines) are the two largest OCaml functions in the repository. They do not share text; each is one long body. | Split each into named phases (setup, the depth loop, witness collection) inside the same file. No new module. |
| SZ4 | Nit | repository | Nothing notices when a file grows back. `lower.ml` did, within a few PRs of being split. | Optional: have `.github/scripts/ci-suites` print the `lib/` files over 1,500 lines as a warning, not a failure. 1,500 is the size the first proposal accepted for one recursive walk. |

---

## 4. Semantics state

| # | Tag | Path | Finding | Proposal |
|---|---|---|---|---|
| ST1 | Should | `lib/tst/model/env.ml`, `model/ty.ml`, `check/context.ml`, `analyses/moves.ml` | Four counters are never reset: `Env.next_decl`, `Context.next_local`, `Moves.next_block`, and the one hidden in the closure of `Ty.fresh_param`. `Env.reset` clears 16 of `Env`'s globals, but not `next_decl`. So a second `Tst.check` in the same process numbers its declarations, locals and type parameters from where the first one stopped, and its `--tst` output differs. This was checked by running `Tst.check` twice on `tests/codegen/fixtures/lambdas`: the first tree has `Int #1` where the second has `Int #23`. Nothing does that today: `zanec` and `span_dump` each check once. But it is the first thing that a language server, a watch mode, or an in-process test runner would do. | Reset all four where the rest of their pass's state is reset, or move them into `Env` and reset them in `Env.reset`. `fresh_param` needs its counter moved out of the closure first. This is a small fix each, and it can come before ST2. |
| ST2 | Should | `lib/tst/` | Semantics keeps its state in 38 module-level tables and references across 12 modules. `Env` has 17. `Instances` has 5. `Type_decls`, `Verb_signatures`, `Owners`, `Read_only`, `Overloads` and `To_span_text` have 2 each. `Context`, `Check`, `Spawns` and `Moves` have 1 each. Each pass resets its own share at its start. As a result: no function says in its parameters what it reads or writes; two checks cannot run at once (for example, on OCaml 5 domains); and every new table is one more chance to forget a reset (ST1). | In two steps. First, move every table into `Env`, and give it one `reset`. This is mechanical and changes no behavior. Second, make `Env` a record created per check and threaded through the passes as an argument. The second step is large, so do it pass by pass, starting with the analyses: they read `Env` and write only their own tables. |
| ST3 | Nit | `lib/tst/model/env.ml` (`note`) | `Env.note` is a global string that is attached to diagnostics as context, for example "in `f`, which nothing instantiates". It is set at 3 sites in `check/check.ml` and restored by hand after each. An exception between the set and the restore leaves it set for every later diagnostic. | Add `Env.with_note : string -> (unit -> 'a) -> 'a` that uses `Fun.protect`, and use it at all 3 sites. |
| ST4 | Nit | `lib/cst/to_span_text.ml`, `lib/sst/to_span_text.ml`, `lib/tst/render/to_span_text.ml` | Each span renderer keeps its printer in a global `ref`, and replaces it at the start of every render. The TST renderer also keeps a global `sources` function. | Create the printer in `render` and pass it down as an argument. |

---

## 5. Shared helpers

| # | Tag | Path | Finding | Proposal |
|---|---|---|---|---|
| SH1 | Should | `lib/tst/analyses/`, `lib/tst/model/env.ml` | Small helpers are written several times. `quote` is defined in `Env` and again in `guests`, `moves`, `owners` and `read_only`. `is_guest` is in `guests`, `owners` and `cgt/type_layout`. `strip` is in `spawns` and `cgt/type_layout`, even though `Ty.strip_guest` already exists. `signature_of` (a `Verb_ref` to its signature, intrinsics included) is written in full in both `guests` and `read_only`, and `spawns` aliases the one in `read_only`. | Use `Env.quote` and `Ty.strip_guest`. Add `Ty.is_guest`, and add `Env.signature_of` beside `Env.signatures`. Delete the copies. |
| SH2 | Nit | `lib/tst/analyses/owners.ml`, `read_only.ml` | Both analyses compute per-verb summaries to a fixpoint, with the same scaffolding: a `summaries` table, a `changed` flag, a `summary_of` lookup, and a `settle` loop in `run` that walks every body until nothing changes, then walks them once more to report. | Once ST2's first step is done, extract a small `Fixpoint` helper (table, change tracking, the loop) that both use. Each one's own `merge` stays where it is. |
| SH3 | Should | `lib/codegen/emit.ml` (`runtime`), `runtime/zane.h` | The runtime's ABI is declared twice: as C prototypes in `zane.h`, and as a 30-way string match in `Emit.runtime`. Call sites name runtime functions by string (`call_runtime env b "zane_mint" …`). A misspelled name is a `failwith` the first time the path runs. An `i32` in one table where the other has an `i64` is caught by nothing: neither LLVM nor the linker sees C types. | Replace the strings with a variant (`type fn = Print \| Text_join \| …`) that has one `name` and one `signature` function. Then a misspelling is a compile error. Add a test that compares each variant's name and complete signature (return type and every parameter type) with the matching prototype in `zane.h`, so the two declarations cannot drift. Names and arities alone would miss the `i32`/`i64` mismatch above. |

---

## 6. Invariants and internal errors

| # | Tag | Path | Finding | Proposal |
|---|---|---|---|---|
| IV1 | Must | `analyses/read_only.ml:89`, `:115`; `analyses/guests.ml:55`; `check/context.ml:107`; and `passes/type_decls.ml:63`, `:283`; `analyses/spawns.ml:144`; `cgt/type_layout.ml:20` | Pairing a generic type's parameters with its arguments, for `Ty.subst`, is written out eight times, and two policies contradict each other. The first four sites catch `Invalid_argument` and continue, with no substitution or with the type unsubstituted. The last four let it raise. `Type_decls.apply_args` reports a wrong argument count and produces no type, so a `Named` type with a wrong count can only come from a compiler bug. That makes the four guards wrong: they turn that bug into a wrong answer from an analysis instead of an error. | Add `Ty.instantiate : param list -> arg list -> t -> t`, plus the binding list behind it. On a mismatch it raises the internal error from IV2. Replace all eight sites with it. |
| IV2 | Should | `lib/`, `bin/zanec/zanec.ml` | Nothing in the compiler marks an error as the compiler's own fault. A broken invariant ends `zanec` with an uncaught exception: `Fatal error: exception Invalid_argument("option is None")`, with no span, no hint that this is a compiler bug, and the same exit status 2 as a usage error. The sources of these are 7 `failwith`, 1 `assert false` and 5 `invalid_arg` in `lib/`, plus partial functions: 31 call sites in `emit.ml`, 7 in `lower.ml`, 5 in `type_layout.ml` and 4 in `check.ml`. | Add `Diagnostic.Internal` (an exception) and `Diagnostic.bug : ?span:Source.Span.t -> string -> 'a` in `lib/diagnostic/`. Use it for every "an earlier stage guarantees this" in `lib/`. In `zanec`, catch it once, together with any other exception as a last resort. Print `internal compiler error: …`, with the span when there is one and a line asking for a report, and exit with a status of its own. |
| IV3 | Should | `lib/codegen/emit.ml` | `expr` returns `llvalue option` (`None` for a `Void` expression), and 13 call sites unwrap it at once with `Option.get (expr env fr b …)`. When one of them is wrong, the message is `option is None`, and it does not say which node. | Add `value env fr b e : Llvm.llvalue`. It calls `expr` and raises `Diagnostic.bug` naming the node's kind and type. Use it at the 13 sites. |
| IV4 | Nit | `check/overloads.ml:181`, `passes/type_decls.ml:394`, `cgt/type_layout.ml:116`, `:157`, `cgt/lower.ml:305`, `:1010`, `:1286` | The other `Option.get`s are local, and each could be avoided. `overloads.ml` checks `List.exists Option.is_none` and then calls `List.map Option.get`. `type_decls.ml` sets `alias.target` and immediately reads it back. `type_layout.ml` calls `array_of` again after a match that already decided the type is an array. | Write `all_some : 'a option list -> 'a list option` for the first. Return `t` directly in the second. Bind the element type and length in the pattern for the third. For the three in `lower.ml`, carry the value that the enclosing match already has. |
| IV5 | Must | `lib/cgt/state.ml` (`problem`), `lib/cgt/lower.ml:1872`, `:1907`, `bin/zanec/zanec.ml:291` | Lowering's error type is `Diagnostic of Diagnostic.t \| Message of string`. `Message` is used twice. One use is "no packages", which assembly makes impossible. The other is "the root package `x` declares no `main` to start from". `zanec`'s `check_kind` reports the same fact for `--kind application`, worded differently: "the application `x` declares no `main` to start from". So one rule has two checks and two messages, and which one a user sees depends on the flags. | Check for `main` once, after semantics, in the driver (DR1), with one message. Make "no packages" a `Diagnostic.bug`. Remove `Message`, so `Cgt.lower` returns `(Program.t, Diagnostic.t) result`. |
| IV6 | Should | `lib/cgt/lower.ml` (`refuse`) | Lowering refuses at 54 sites, and their messages are three different kinds. 21 say "lowering does not handle … yet". Those are real limits of the compiler, and the user should see them. 27 say "lowering expected …" or "lowering found no …". Those are invariants that semantics should already have established, so they are internal errors that are shown to the user as if the program were at fault. Five of the others are errors in the program, and one passes its message in a variable. Semantics already reports three of the five, so in lowering they are invariants too: an enum map with no entry for a member (`Verb_signatures.enum_map`), a spawned verb that takes a block (`check.ml:982`), and an "exit ends the block…, and this is in none" case. Two are found only by lowering: a verb that "expands into itself", and a `main` that can exit (semantics checks only that `main` declares no abort type). `zanec --check` accepts such a program, and `--build` then rejects it. | Keep `refuse` for "does not handle … yet". Turn the "expected …" and "found no …" sites, and the ones semantics already reports, into `Diagnostic.bug`. Move the two checks only lowering has into semantics, so `--check` reports them. List the remaining "does not handle" cases in `docs/design/lowering.md`, so the set of unsupported constructs can be read without searching for them. Test them as in TS1. |

---

## 7. Interfaces and entry modules

| # | Tag | Path | Finding | Proposal |
|---|---|---|---|---|
| IF1 | Should | `lib/` | **L1, still open.** There is still not a single `.mli` in `lib/`. One cost this review found: two dead functions that warning 32 would report if there were an interface. They are `Context.signature_home`, which is also the identity function wrapped in `Some`, and `Env.find_package`. | Delete both now. Then add interfaces as L1 says, bottom up. |
| IF2 | Should | `lib/*/{cst,sst,tst,cgt}.ml` | **L2, still open.** `Cst` and `Sst` `include To_tree_graph`, while `Tst` and `Cgt` bind `to_node` with a `let`. Five re-exports are used by nothing outside their library: `Cst.Parser`, `Cst.Lexer`, `Cst.Span`, `Sst.Span` and `Sst.Lower`. `Cst.Span`'s comment says it is kept "so a caller that has a `Cst.Span.t` keeps working", but no such caller exists. | Remove the five unused re-exports. Then give every entry module the same shape, as L2 proposes, and let the `.mli` from IF1 hold it. |

---

## 8. The driver

| # | Tag | Path | Finding | Proposal |
|---|---|---|---|---|
| DR1 | Should | `bin/zanec/zanec.ml` (431 lines) | B3 said to leave the pipeline in the binary until a second front end appears. There is a second one now: `tools/inspect/span_dump.ml` repeats assemble → check → render diagnostics. The binary also holds rules that are not about arguments: whether the root declares `main` (`check_kind`, which walks `Tst.Nodes`), how stamps are matched to packages (`with_stamps`), and that a library cannot be built into an executable. | Add `lib/driver/`, with one function per step (`assemble`, `check`, `lower`, `emit`). Each step returns `(_, Diagnostic.t list) result`, and the rules above move into it. Then `zanec.ml` parses arguments and prints, and so does `span_dump.ml`. |
| DR2 | Nit | `bin/zanec/zanec.ml` | Four error types reach the binary: `Diagnostic.t` (from the parser, semantics and lowering), `Assembly.problem` with its own renderer (T4), lowering's `Message` (IV5), and plain strings from codegen. The binary also calls `exit` from 14 places, many of them inside helpers. | With DR1, IV5 and T4 done, only `Diagnostic.t` is left. Have the helpers return results, and call `exit` once in the binary's top-level `()`. |

---

## 9. Tests

| # | Tag | Path | Finding | Proposal |
|---|---|---|---|---|
| TS1 | Should | `tests/codegen/` | No golden file contains any of lowering's 54 refusal messages, and none contains the "no `main`" path in lowering. Every codegen fixture is a program that lowers. When a "does not handle … yet" case is implemented, or one stops firing by mistake, no test changes. | Add `tests/codegen/fixtures/reject/`, with one small program per "does not handle" message (IV6), and a `golden/reject.NAME.err` for each. Extend `tests/gen/gen_rules.ml` to write their rules, as it already does for the parser's rejects. |
| TS2 | Should | `lib/tst/model/`, `lib/cgt/type_layout.ml` | Every OCaml test is end to end, through a golden file. `Ty.subst`, `Ty.equal`, overload ranking and `Type_layout` have no direct tests. The refactors in §5 and §6 change exactly those helpers. A mistake in one of them shows up as a diff somewhere in a 1,029-line golden, far from the cause. | Add `tests/unit/`, with a dune `test` stanza for `Ty`, `Signature`, `Overloads` and `Type_layout`, and land it *before* IV1 and SH1. Run it from `test-compiler`. |
| TS3 | Nit | `tests/semantics/dune` | Its 24 rules are written by hand. The parser, codegen and runtime suites have theirs generated by `gen_rules.ml` (S11, S12). | Have `gen_rules.ml` also write the semantics rules that follow a pattern (each `typing`/`assembly` accept/reject pair), and leave the `project.*` cases by hand. |

---

## 10. Docs

| # | Tag | Path | Finding | Proposal |
|---|---|---|---|---|
| DC1 | Must | `tests/codegen/fixtures/range/main.zn:2`, `tests/codegen/fixtures/zero/main.zn:2`, `tests/parser/fixtures/desugar.zn:1` | These cite `docs/lowering.md §9` and `docs/desugaring.md §2`. Both files moved to `docs/design/` (O5). | Update the three comments. Re-run `just test-compiler`, and `just promote` if any span moves. |
| DC2 | Must | `docs/design/lowering.md` §7 | It says the runtime's source is "`runtime/zane.c`". That file no longer exists in the source tree: the runtime is nine `.c` files, which `runtime/dune` joins into a generated `zane.c` (U1, U3). | Describe the parts and the generated file, and point to `runtime/dune`. |
| DC3 | Should | `docs/file-structure-proposal.md` | Its header is accurate, but its body states facts that have since changed, in the present tense: "`check.ml` is 2,215 lines", "`lower.ml` is 1,808 lines". A reader who opens it from `docs/README.md` cannot tell which statements still hold. | Once this document lands, change its status line to "carried out; the open items moved to `refactoring-proposal.md` §11". Keep the body as the record of that review. |

---

## 11. Carried over from the file-structure proposal

These items are still open in [`file-structure-proposal.md`](file-structure-proposal.md).
Each one was checked against the tree. They are tracked here from now on.

| # | Tag | Where it stands now |
|---|---|---|
| L1 | Should | Open. See IF1. |
| L2 | Should | Open. See IF2. |
| G1 (remainder) | Should | The Verbs section has no sub-banners yet. It is now 1,700 lines, not 1,290. See SZ1. |
| A1 (remainder) | Should | `tools/ambiguity/engine/run.ml` still opens six modules wholesale, and `concretize.ml` opens five. `config.ml` still parses options into 9 module-level `ref`s, not a record. |
| T4 | Nit | Open. `Assembly.render_problem` and `Semantics.render` are still two renderers. It is now part of DR2. |
| D3 | Nit | Open. `dev/bin/bootstrap-toolchain` is still in `dev/bin/`. |
| P2 | Nit | Open. There is no `pyproject.toml`. |
| R13 | Nit | Open. There is no `.editorconfig` or `.ocamlformat`. |
| H1 | Should | Open. `.github/agents/implementation-specialist.md` is still in this repo. |
| H3 | Should | Open, and it has drifted further. `ci.yml` and `copilot-setup-steps.yml` use floating tags. The other three workflows pin by SHA, but at different versions: `actions/checkout` at v6.0.2 and v6.1.0, `devbox-install-action` at v0.14.0 and v0.15.0, and `upload-artifact` at v4.6.2 and v7.0.1. |
| Q1 | Should | Partial. New run output is ignored (`/reports/` in `.gitignore`), but the committed files under `reports/ambiguity/` stay as evidence for `docs/ambiguity/`. |

---

## 12. Migration order

The work lands in four pull requests, each a coherent refactor, each under
the 100 files a review covers. Within a pull request, each item is its own
commit. Golden files pass unchanged after every step, except where a step
says otherwise.

1. **Honest errors and invariants.** DC1, DC2, DC3, ST1, IF1's two
   deletions, IF2's five re-exports; then TS2, the unit tests, before
   anything that changes a helper; then SH1; then IV2, IV3, IV4 and IV1;
   then IV5 with T4, so every error that reaches the driver is a
   `Diagnostic.t`. The one check for `main` stays in `zanec`'s
   `check_kind` until DR1 moves it into `lib/driver/`, and its message is
   the one `project.no-main.err` already holds.
2. **Lowering and the checker.** IV6 sorts lowering's refusals into limits
   and bugs and moves the three checks only lowering has into semantics --
   whether `main` can exit, whether a verb expands into itself, and whether
   a primitive can hold its literal -- so their goldens change, as
   intended. TS1 then pins every limit with a golden file. SZ1 and SZ2 split `lower.ml` and `check.ml`, as pure
   moves.
3. **Architecture.** SH3, the runtime's functions as a variant; DR1 and
   the rest of DR2, `lib/driver/`; ST2's two steps, ST3, ST4 and SH2, one
   `Env` per check; then L1 and L2, as IF1 and IF2 describe, bottom up.
4. **Tools and the repository.** A1's remainder, SZ3, SZ4, H3, TS3, D3,
   P2, R13, H1 and Q1.

---

## 13. What should stay as it is

A strict review can end up recommending changes for their own sake. These
parts are fine as they are:

- **The stage structure.** Each stage is its own library, and every
  dependency points down. The outside review is right about this.
- **One walk per analysis.** `guests`, `moves`, `owners`, `read_only`,
  `exits` and `spawns` each walk the TST themselves. Each walk matches every
  `Expr` constructor exhaustively, so a new constructor is a compile error in
  every analysis until each one decides what to do with it. A shared generic
  fold with a default case would lose that.
- **Diagnostics as values, collected and sorted.** `Semantics.check`
  collects every problem and sorts it into source order (D4). That is the
  right shape. IV2 adds internal errors next to it, without replacing it.
- **`refuse` in lowering.** Refusing a construct, rather than lowering it
  wrongly, is the right policy. IV6 only separates the refusals from
  internal errors.
- **`tests/objects/dune` written by hand.** Its 59 rules are scenarios
  (rewrite, remap, three object formats, version conflicts), not one
  pattern repeated. Generating them would hide what each scenario checks.
- **The files that the first proposal already kept**: the `nodes.ml` of
  each stage, `lib/cst/parser.mly`, `lib/sst/lower.ml`, and the recursive
  cores of `check.ml` and `lower.ml` once SZ1 and SZ2 take out what is not
  recursive.
- **`lib/tst/passes/verb_signatures.ml`** (783 lines). It has four banners,
  and its largest function is 114 lines.
