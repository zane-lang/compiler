# File structure proposal

Status: **proposal**. Nothing here has been moved yet.

This is a strict review of the repository's file layout, written as if the
code came from someone new to the project. It looks at where files sit, not
at what the code does. It covers files that should be split, files in the
wrong directory, files and settings that serve no purpose, names that say
the wrong thing, and places where two parts of the tree follow different
rules. Every finding names the path it is about, so it can be checked
against the tree.

Each finding is tagged:

- **Must**: this is wrong now. A path points somewhere it shouldn't, a
  file is stale, a test runs in the wrong suite, or production code
  depends on a test file.
- **Should**: this is a real structural cost that gets worse as the repo
  grows.
- **Nit**: consistency or tidiness. Cheap to fix, and it adds up.

## Contents

1. [Summary](#1-summary)
2. [Proposed tree](#2-proposed-tree)
3. [Repository root](#3-repository-root)
4. [`bin/`](#4-bin)
5. [`lib/`](#5-lib)
6. [`runtime/`](#6-runtime)
7. [`tools/`](#7-tools)
8. [`dev/`](#8-dev)
9. [`test/`](#9-test)
10. [`docs/`](#10-docs)
11. [`reports/`](#11-reports)
12. [`.github/`](#12-github)
13. [Migration order](#13-migration-order)
14. [What should stay as it is](#14-what-should-stay-as-it-is)

---

## 1. Summary

The stage-by-stage split of the compiler core (`lib/cst`, `lib/sst`,
`lib/tst`, `lib/cgt`, `lib/codegen`, plus `lib/source`, `lib/diagnostic` and
`lib/tree_graph` below them) is sound, and this proposal keeps it. The
problems are around that core:

1. **Stale documents describe a repo that no longer exists.**
   `docs/repository-layout.md` still lists `tools/ambiguity_search.ml` at
   4,816 lines, `tools/syntax_experiment.py`, `tools/ambiguity.py` and
   `test-parser/`. None of these exist any more. `docs/lowering.md` says
   "Status: design … once they are built", but steps 1 to 8 are built and
   tested.
2. **Production code depends on a test file.** `bin/compiler/main.ml`
   uses `test/parser/fixtures/main.zn` as its default input.
3. **Four files are far too large**, and each already has section headers
   that show where it should be split: `lib/tst/check.ml` (2,215 lines),
   `lib/cgt/lower.ml` (1,808 lines, one 1,290-line "Verbs" section),
   `runtime/zane.c` (1,329 lines, 8 sections) and
   `tools/ambiguity/ambiguity_search.ml`. The last one is described as a
   "thin entry point", but it is a single 850-line `main` function after
   eight `open`s.
4. **`lib/tst/` is a flat directory of 20 modules.** Passes, analyses,
   data model and renderers sit side by side, and two pairs of names differ
   by one letter: `ty.ml`/`types.ml` and `signature.ml`/`signatures.ml`.
5. **Tests are not in their mirrored place.** An OCaml test lives in
   `tools/`, and a semantics rejection lives under `test/codegen/`. The
   ambiguity tool's unit test runs in the *compiler* suite. The grammar
   ambiguity tests sit under `test/parser/`. The name `test/` collides with
   Python's standard library, and `__init__.py` files are there only to
   work around that.
6. **Leftovers from another project's scaffolding.** `devbox.json` has
   meson, cmake, ninja, zig and upx, none of which are used, and an npm-style
   `"test": "echo Error: no test specified"`. `.gitignore` ignores
   `vcpkg_installed/`, `build/`, `/parser/` and `*.term`. `dune-project`
   ends with the template's "See the complete stanza docs" comment.
7. **The root holds tool-specific files.** `machine-config.example`,
   `ambiguity-searches.toml` and `enter` are all used by developer tooling
   only.
8. **Generated output is committed.** `reports/` holds 29 run logs, some
   from engine versions that no longer exist.

---

## 2. Proposed tree

This tree shows only what changes. Unchanged files within a directory are
shown as `…`.

```text
.
├── README.md                     # + a layout map and a docs index (§3)
├── LICENSE
├── dune-project                  # + license/authors, current description (§3)
├── zane-compiler.opam            # regenerated
├── devbox.json                   # unused packages and placeholder script removed (§3)
├── devbox.lock
├── justfile
│
├── bin/
│   └── zanec/                    # was bin/compiler/ (§4)
│       ├── dune
│       └── zanec.ml              # was main.ml; no default input
│
├── lib/
│   ├── source/  diagnostic/  tree_graph/   # unchanged
│   ├── cst/
│   │   ├── cst.ml                # re-exports only
│   │   ├── parse.ml              # Cst.parse + byte_positions, moved out of cst.ml
│   │   └── …
│   ├── sst/                      # unchanged
│   ├── tst/
│   │   ├── dune                  # (include_subdirs unqualified)
│   │   ├── tst.ml
│   │   ├── semantics.ml          # the pipeline
│   │   ├── model/                # nodes, ty, signature, env, intrinsics
│   │   ├── passes/               # assembly, collect, type_decls, verb_signatures
│   │   ├── check/                # check.ml split along its sections (§5.3)
│   │   ├── analyses/             # read_only, guests, moves, owners, exits, spawns
│   │   └── render/               # to_tree_graph, to_span_text
│   ├── cgt/
│   │   ├── cgt.ml  nodes.ml  to_tree_graph.ml
│   │   ├── state.ml              # lower.ml "State"
│   │   ├── layout.ml             # lower.ml "Types"
│   │   ├── literals.ml           # lower.ml "Literals"
│   │   └── lower.ml              # the recursive walk only
│   └── codegen/                  # emit.ml gains section headers (§5.5)
│
├── runtime/                      # split, with a header (§6)
│   ├── dune                      # builds the embedded text
│   ├── zane.h
│   ├── main.c  arena.c  anchor.c  block.c  value.c
│   └── list.c  slot.c  spawn.c  snapshot.c
│
├── tools/
│   ├── ambiguity/
│   │   ├── __init__.py           # an actual package, no sys.path hack (§7.2)
│   │   ├── cli.py  profiles.py  runner.py
│   │   ├── precision_sweep.py  explain_automaton.py  conflict_census.py
│   │   ├── profiles.toml         # was /ambiguity-searches.toml
│   │   └── engine/               # the OCaml half (§7.1)
│   │       ├── dune
│   │       ├── ambiguity_search.ml   # thin: parse args, call Run.main
│   │       ├── arguments.ml          # was the first half of `main`
│   │       ├── run.ml                # was the second half of `main`
│   │       ├── history_filter.ml
│   │       └── automaton.ml  stack_pool.ml  recognizer.ml  abstraction.ml
│   │           prover.ml  search.ml  output.ml  config.ml
│   └── inspect/                  # was tools/parser/ (§7.3)
│       ├── dune
│       ├── parser_shape.ml
│       └── span_dump.ml
│
├── dev/
│   ├── bin/                      # `compiler` → `zanec`; grammar-* stop sourcing ambiguity config
│   ├── lib/
│   │   ├── ambiguity-config.sh
│   │   └── menhir.sh             # AMBIGUITY_MENHIR alone, for grammar-* (§8)
│   └── machine-config.example    # was at the root
│
├── tests/                        # was test/ (§9.1)
│   ├── parser/                   # syntax_test.py, span/tree/reject goldens
│   ├── grammar/                  # ambiguity_test.py, the two conflict censuses
│   ├── semantics/
│   │   └── fixtures/
│   │       ├── assembly/{accept,reject}/
│   │       └── typing/{accept,reject}/   # + codegen's `temporary`
│   ├── codegen/                  # dune rules generated, not hand-copied (§9.5)
│   ├── runtime/
│   │   ├── *.c
│   │   └── golden/*.out
│   └── ambiguity/
│       ├── cli_test.py  profiles_test.py  engine_test.py   # cli_test.py split (§9.4)
│       ├── prover/
│       ├── history_filter_test.ml              # was in tools/
│       └── grammars/verb_suffix_vs_enum_map.mly
│
├── docs/
│   ├── README.md                 # index
│   ├── spec-divergences.md
│   ├── design/                   # stages, desugaring, semantics, lowering,
│   │                             # generics, concepts-vs-primitives
│   └── ambiguity/
│       ├── README.md             # was docs/ambiguity.md
│       └── policy.md  proof-obligations.md  tooling.md  soundness.md  experiments.md
│
└── .github/                      # agents file moved to the org; setup steps fixed (§12)
```

The following are removed: `enter`, `reports/`, `docs/repository-layout.md`,
`docs/ambiguity/research-handoff.md`, `.github/agents/implementation-specialist.md`,
and the root copies of `machine-config.example` and `ambiguity-searches.toml`.

---

## 3. Repository root

| # | Tag | Path | Finding | Proposal |
|---|---|---|---|---|
| R1 | Should | `machine-config.example` | Only `dev/lib/ambiguity-config.sh` reads the file, and only for the ambiguity tools. It doesn't belong at the root. | Move it to `dev/machine-config.example` and have the script read `dev/machine-config.txt`. Update the `.gitignore` entry to match. |
| R2 | Should | `ambiguity-searches.toml` | Only `tools/ambiguity/profiles.py` reads it. `docs/repository-layout.md` argued it should stay at the root as "repository-level configuration", but it configures a single developer tool. `justfile`, `dune-project` and `devbox.json` are root-level because they concern the whole repo; this file doesn't. | Move it to `tools/ambiguity/profiles.toml`, next to its loader. `--profiles-file` still overrides it. |
| R3 | Nit | `enter` | A five-line wrapper around `devbox shell`. The only thing it adds is a `cd` to the root, and `devbox shell` already finds the project from any subdirectory. It is one more non-standard file at the root. | Delete it. The README says `devbox shell` instead. |
| R4 | Must | `devbox.json` | `meson`, `cmake`, `ninja`, `zig` and `upx` appear nowhere else in the repo. `gnumake` is only mentioned in prose. `clang-tools` is never invoked. They make every cold shell and every CI run slower. | Remove them. Keep `clang-tools` only if it is there on purpose for `clangd` in editors, and if so, say so in a comment in `README.md`, since JSON can't hold one. |
| R5 | Must | `devbox.json` | `"scripts": {"test": ["echo \"Error: no test specified\" && exit 1"]}` is npm's `package.json` placeholder. | Replace it with `"test": ["just test"]`, or delete the block. |
| R6 | Nit | `devbox.json` | The first init hook is `echo 'Welcome to devbox!'`, template noise printed on every `devbox run` in CI. | Delete it. |
| R7 | Must | `.gitignore` | `vcpkg_installed/`, `build/`, `/parser/`, `.cache/` and `*.term` don't match anything this repo produces. `vcpkg` is a C++ package manager. | Delete them. |
| R8 | Must | `.gitignore` | `reports/ambiguity/actions/` is where all three ambiguity workflows write, and where the `quick` profile writes locally (`reports/ambiguity/search/quick/…`), but neither path is ignored. Every local quick search leaves an untracked file behind. | Ignore the output directory. See §11 for where it should go. |
| R9 | Nit | `dune-project` | It ends with `; See the complete stanza docs at …`, which is `dune init` boilerplate. | Delete it. |
| R10 | Should | `dune-project` | The description says "a sedlex lexer, a Menhir GLR grammar producing a concrete syntax tree, and the developer tooling". It predates semantics, lowering, codegen and the runtime. | Rewrite it for all six stages. |
| R11 | Should | `dune-project` | `LICENSE` is GPL-3.0, but the package has no `(license …)`, `(authors …)` or `(maintainers …)`, so the generated `zane-compiler.opam` carries none of them. | Add all three and regenerate the opam file. |
| R12 | Should | `README.md` | It doesn't mention `runtime/`, `docs/` or the test layout. It calls the binary `compiler`, but the installed name is `zanec` (`bin/compiler/dune`: `public_name zanec`). "The `justfile` is reserved for parameterless project actions" isn't true: `sweep` and `explain` take arguments. | Add a short "Where things are" map that links to `docs/README.md`, call the binary `zanec` throughout, and fix the `justfile` sentence. |
| R13 | Nit | root | There are no `.editorconfig` or `.ocamlformat` files, though `.github/agents/implementation-specialist.md` sets out a tabs policy with exceptions. Formatting rules that exist only in an agent prompt aren't enforced. | Add `.editorconfig` (and `.ocamlformat` if OCaml formatting is to be fixed), and have the prose point to them. |

---

## 4. `bin/`

| # | Tag | Path | Finding | Proposal |
|---|---|---|---|---|
| B1 | Must | `bin/compiler/main.ml` | `let default_path = "test/parser/fixtures/main.zn"`. The shipped binary reads a test fixture, found relative to the working directory, when it gets no arguments. It only works from the repo root and breaks as soon as the test tree moves. The comment even says it was meant for "while the front end is the only stage", which is no longer the case. | Remove the default. With no arguments, print usage. `dev/bin/compiler` can pass the sample path itself if that shortcut is still wanted. |
| B2 | Should | `bin/compiler/` | The directory is `compiler`, the module is `main`, the executable is `main.exe`, the public name is `zanec`, the dev wrapper is `dev/bin/compiler`, and `usage ()` prints `usage: compiler`. That is four names for one program. | Rename it to `bin/zanec/zanec.ml`, and use `zanec` for the dev wrapper and the usage text. Dune rules then refer to `%{exe:../../bin/zanec/zanec.exe}`. |
| B3 | Nit | `bin/compiler/main.ml` | `run_packages` and `generate` also handle view dispatch and diagnostic printing, which would all be the same in a second front end, such as an LSP. | Nothing to do now. If a second binary appears, move the pipeline into a `lib/driver/` library and keep the binary to argument parsing. |

---

## 5. `lib/`

### 5.1 Across all libraries

| # | Tag | Finding | Proposal |
|---|---|---|---|
| L1 | Should | **There isn't a single `.mli` file in the repo.** Every helper in every module is public API: `Cst.Statement_shape.*`, `Tst.Check.*` and all the rest. Nothing marks what a stage promises to the next one, and the compiler can't report dead code. | At minimum, add an interface for each library's entry module (`cst.mli`, `sst.mli`, `tst.mli`, `cgt.mli`, `codegen.mli`, `diagnostic.mli`, `tree_graph.mli`, `source`'s modules). Add `.mli` files for internal modules as they settle. |
| L2 | Should | **The entry modules use different conventions.** `Cst` and `Sst` `include To_tree_graph`, so `Cst.to_node` comes in through an `include`. `Tst` declares `let to_node = To_tree_graph.to_node`. `Cgt` declares `let to_node = To_tree_graph.program`. Span output is `Cst.To_span_text` (a module), `Sst.To_span_text` (a module) and `Tst.to_span_text` (a function). `Tst` re-exports six of its twenty modules; `Cst` re-exports four of eleven. | Pick one shape and apply it to every stage: an explicit `val to_node`, an explicit `val to_span_text` (or no span output at all), and the pass entry point (`parse`/`of_cst`/`check`/`lower`). Decide deliberately which submodules are re-exported, and let the `.mli` from L1 enforce it. |
| L3 | Nit | Every library directory is named after the tree it produces (`cst`, `sst`, `tst`, `cgt`) except `codegen`, which is named after the stage. | Leave it as it is: codegen produces no tree. Add one sentence to `docs/design/stages.md` saying so, so nobody "fixes" it later. |

### 5.2 `lib/cst/`

| # | Tag | Path | Finding | Proposal |
|---|---|---|---|---|
| C1 | Should | `lib/cst/cst.ml` | Every other entry module is a list of re-exports. This one also contains the whole `parse` driver (UTF-8 handling, the tokenizer closure, error mapping, the statement check) and `byte_positions`. | Move them to `lib/cst/parse.ml` and have `cst.ml` re-export `let parse = Parse.package`. |
| C2 | Nit | `lib/cst/parser.mly` | The prologue was extracted as planned. What remains is 1,540 lines of grammar in one file, which is correct: precedence and conflict work need it in one place. | No change. Listed so it isn't split by mistake. |

### 5.3 `lib/tst/`: the biggest structural issue in `lib/`

There are 20 modules in one flat directory, and the list mixes four different
kinds of file:

| Kind | Files |
|---|---|
| Data model | `nodes.ml`, `ty.ml`, `signature.ml`, `env.ml`, `intrinsics.ml` |
| Passes (docs/semantics.md §3) | `assembly.ml`, `collect.ml` (passes 1–2), `types.ml` (pass 3), `signatures.ml` (pass 4), `check.ml` (pass 5) |
| Analyses over the finished TST (D1) | `read_only.ml`, `guests.ml`, `moves.ml`, `owners.ml`, `exits.ml`, `spawns.ml` |
| Output | `to_tree_graph.ml`, `to_span_text.ml` |
| Pipeline and entry | `semantics.ml`, `tst.ml` |

| # | Tag | Finding | Proposal |
|---|---|---|---|
| T1 | Should | The kind of a file can only be found by opening it. | Use `(include_subdirs unqualified)` in `lib/tst/dune` and create `model/`, `passes/`, `check/`, `analyses/` and `render/`. With `unqualified`, no module names change, so the move doesn't touch any code. |
| T2 | Must | `ty.ml` and `types.ml`, and `signature.ml` and `signatures.ml`, differ by one letter but do completely different jobs. `ty.ml` is the type *representation*; `types.ml` is *pass 3*. `signature.ml` is a *record*; `signatures.ml` is *pass 4*. People will open the wrong one. | Name the passes after what they do: `types.ml` → `type_decls.ml` (it resolves `type`/`alias` right-hand sides) and `signatures.ml` → `verb_signatures.ml`. The model files keep the short names. |
| T3 | Should | `check.ml` is 2,215 lines. It already has 13 banner sections: Context, Types of things, Instances, Overload resolution (275 lines), Termination, Expressions, Handlers, Calls (570 lines), Match, Lambdas, Statements, Subscripts, Verb bodies. | Split out the sections that are *not* part of the mutually recursive `expr`/`stmt` walk: `check/context.ml` (Context, Types of things), `check/instances.ml`, `check/overloads.ml` and `check/termination.ml`. The recursive core (expressions, handlers, calls, match, lambdas, statements, subscripts, bodies) stays in `check/check.ml`. The expected result is about 1,500 lines, all of it one recursive walk, which is the kind of file the old proposal rightly chose not to split. Confirm each extracted section has no back-edge into the walk before moving it. |
| T4 | Nit | `semantics.ml` contains `render`, which formats diagnostics against the package sources, and `Tst` re-exports it as `render_diagnostic`. `Assembly` has its own `render_problem` for a separate error type that isn't a `Diagnostic.t`. There are two error types and two renderers for one stage. | Make assembly problems into `Diagnostic.t` values, and move "find the source for a span across packages" into `lib/source/` (for example `Source.Files`). Then `bin/` renders everything the same way. |

### 5.4 `lib/cgt/`

| # | Tag | Finding | Proposal |
|---|---|---|---|
| G1 | Should | `lower.ml` is 1,808 lines with only five banners, and one of them, "Verbs", covers lines 424–1714: a single 1,290-line section. The State (95 lines), Types (254 lines) and Literals sections are support code for the walk, not the walk itself. | Extract `state.ml`, `layout.ml` (the Types section: how a TST type becomes a CGT layout) and `literals.ml`. Inside what remains of `lower.ml`, add sub-banners to the Verbs section that follow `docs/lowering.md`'s numbered decisions, so the next split has visible boundaries. |

### 5.5 `lib/codegen/`

| # | Tag | Finding | Proposal |
|---|---|---|---|
| E1 | Nit | `emit.ml` is 594 lines with no section banners, while every other large file in `lib/` has them. | Add banners using the same headings as the CGT node groups. |
| E2 | Nit | `lib/codegen/dune` embeds `../../runtime/zane.c` by relative path. That works, but it means codegen owns the runtime's build. | After §6, `runtime/dune` produces the embeddable text, and codegen depends on it by name. |

---

## 6. `runtime/`

| # | Tag | Finding | Proposal |
|---|---|---|---|
| U1 | Should | `runtime/zane.c` is 1,329 lines in 8 banner sections: scope arenas, anchors and tethers, dynamic blocks, values arriving and leaving, lists, slots and drains, spawned calls, snapshots. It also contains `main`. | Split it into `zane.h` (the ABI that emitted code calls) plus one `.c` per section and `main.c`. |
| U2 | Must | The C tests `#include "../../runtime/zane.c"`: they include a *.c file* through a relative path. Every test recompiles the whole runtime, and gets its `main` and its internal `static` helpers along with it. | The tests should `#include "zane.h"` and link the runtime objects. A test that needs internals can get them from a `zane_internal.h`. |
| U3 | Should | The runtime is embedded as one string (`Runtime_source.text`). | Let `runtime/dune` concatenate the parts in a fixed order into the embedded text. That keeps "build from anywhere" working without making the source a single file. |

---

## 7. `tools/`

### 7.1 `tools/ambiguity/`: engine

| # | Tag | Path | Finding | Proposal |
|---|---|---|---|---|
| A1 | Must | `ambiguity_search.ml` | Its header comment calls it the entry point that "hands the work to the modules beside it". In fact it is `open Output`, `open Automaton`, `open Stack_pool`, `open Recognizer`, `open Abstraction`, `open Prover`, `open Search`, `open Config`, followed by a single `let main () =` running from line 20 to line 873. The earlier split left the monolith inside `main`. Eight blanket `open`s also make it impossible to tell where any name comes from. | Split `main` at the point where the parsed arguments are complete: `arguments.ml` (option parsing into a record) and `run.ml` (temporary directories, cleanup, dispatch to prove, search, survey or refine). `ambiguity_search.ml` then really is a thin entry point. Replace the blanket `open`s with qualified names or local `let open`s. |
| A2 | Should | `tools/ambiguity/` | The directory holds eleven `.ml` files, six `.py` files, one `dune`, one `.mly` fixture and one OCaml test, all in one flat directory. The OCaml engine and the Python front end are two programs that talk to each other only through a subprocess boundary. | Move the OCaml engine to `tools/ambiguity/engine/` with its own `dune`. The Python stays one level up as the package. |
| A3 | Must | `history_filter_test.ml` | This is a test in the tools tree. `justfile` has `test-ambiguity-tools` for exactly this, but that recipe runs only Python. This test runs under `dune runtest`, which is in **`test-compiler`**. CI's `ci-suites` skips the tools suite when a change touches only compiler files, and runs the compiler suite on every PR. The result is that an ambiguity-tool test runs on unrelated PRs and is attributed to the wrong suite. | Move it to `tests/ambiguity/history_filter_test.ml` and run it from `test-ambiguity-tools` (`dune test tests/ambiguity`). |
| A4 | Should | `history_filter.ml` | It is its own library, `ambiguity_history`, with `(wrapped false)`, and it exists only so the test can link it. | After A2, make the whole engine a wrapped library (`ambiguity_engine`) with the executable as a thin `main`. The test links that library, and the one-module special case goes away. |
| A5 | Should | `grammars/verb_suffix_vs_enum_map.mly` | A grammar kept as a known blind spot, used only as the default input of `.github/workflows/ambiguity-sweep.yml`. It is test data, not tool source. | Move it to `tests/ambiguity/grammars/` and update the workflow default. |

### 7.2 `tools/ambiguity/`: Python

| # | Tag | Finding | Proposal |
|---|---|---|---|
| P1 | Should | `tools/` and `tools/ambiguity/` have no `__init__.py`, so they are *namespace* packages. `cli.py` works around that by putting the repo root on `sys.path` before importing `tools.ambiguity.*`, and `dev/bin/ambiguity` runs it by file path. The tests import `tools.ambiguity` and only work because the repo root happens to be the working directory. | Add `tools/__init__.py` and `tools/ambiguity/__init__.py`, have `dev/bin/ambiguity` run `python3 -m tools.ambiguity.cli` from the root, and delete the `sys.path` insertion. |
| P2 | Nit | There is no `pyproject.toml`. Python style, the minimum Python version (`tomllib` needs 3.11) and test discovery are all unwritten. | Add a minimal `pyproject.toml` with `requires-python` and ruff/pytest settings, even if they are never published. |
| P3 | Nit | `conflict_census.py` is run by `test/parser/dune` to check the *shipped* parser's conflicts. That makes it a grammar-ledger tool as well as an ambiguity tool. | Keep it where it is, but move the test that uses it to `tests/grammar/` (§9.3). |

### 7.3 `tools/parser/`

| # | Tag | Path | Finding | Proposal |
|---|---|---|---|---|
| X1 | Must | `span_dump.ml` | The directory's `dune` describes it as "Parser developer tools", but `span_dump` also takes `--tst --package …`, runs the *whole semantics stage*, and is what `test/semantics/dune` uses. It isn't a parser tool. | Rename the directory `tools/inspect/`. If the name "parser tools" matters more, move span output into the compiler binary as a hidden `--spans` view, next to `--cst`, `--sst` and `--tst`, and delete the executable. |
| X2 | Nit | `parser_accept.ml` | Ten lines doing what `zanec --cst - >/dev/null` does. It exists because the Python tests pass source text as `argv[1]` instead of on stdin. | Make `syntax_test.py` write to the compiler's stdin, and delete it. That leaves one fewer executable to build in `test-compiler`. |

---

## 8. `dev/`

| # | Tag | Path | Finding | Proposal |
|---|---|---|---|---|
| D1 | Must | `dev/bin/grammar-stat`, `dev/bin/grammar-sentence` | Both source `dev/lib/ambiguity-config.sh` only to get `AMBIGUITY_MENHIR`. That script exits with an error unless **all four** ambiguity settings are set, so `grammar-stat`, a plain `menhir --infer`, fails on a machine that has no memory budget configured for a search it isn't running. | Add `dev/lib/menhir.sh`, which sets `MENHIR=${AMBIGUITY_MENHIR:-menhir}`, and source that instead. |
| D2 | Should | `dev/bin/compiler` | The name will differ from the real binary once B2 is done. | Rename it `dev/bin/zanec`. |
| D3 | Nit | `dev/bin/bootstrap-toolchain` | CI calls it directly, and the devbox init hook calls it too. It is provisioning, not a developer command, and it is the only file in `dev/bin` a person never types. | Optional: move it to `dev/setup/bootstrap-toolchain` so `dev/bin` holds only commands for people. If you do, update `ci-suites`' SHARED list and the cache key hash. |

---

## 9. `test/`

### 9.1 The root name

| # | Tag | Finding | Proposal |
|---|---|---|---|
| S1 | Should | `test/__init__.py` exists, as its comment explains, only because Python's standard library ships a package named `test`, and `python3 -m unittest test.parser.syntax_test` would otherwise import the wrong one. That is a workaround for a name collision, not a design. | Rename `test/` to `tests/`. The `__init__.py` files can stay as ordinary package markers, but they no longer carry a warning. This is the most disruptive move in the proposal, so do it in its own mechanical PR (§13). |

### 9.2 Placement

| # | Tag | Path | Finding | Proposal |
|---|---|---|---|---|
| S2 | Must | `test/codegen/fixtures/temporary/` | Its own dune comment says "Semantics rejects it before lowering starts." It is a semantics test filed under codegen. | Move it to `tests/semantics/fixtures/typing/reject/` and fold its expectation into that golden. |
| S3 | Should | `test/parser/ambiguity_test.py` | Its recipe is `test-grammar`, not `test-compiler`. It tests the grammar's ambiguity, not the parser's output. | Move it to `tests/grammar/ambiguity_test.py`. |
| S4 | Should | `test/parser/golden/parser.conflicts.census`, `stock.conflicts.census` and their rules | These are the conflict ledger from `docs/ambiguity/proof-obligations.md`, not parser output. | Move them to `tests/grammar/` with their own `dune`. |
| S5 | Nit | `test/runtime/*.out` | Every other suite keeps expectations in `golden/`, but here they sit next to the `.c` files. | Move them to `tests/runtime/golden/`. |

### 9.3 Fixture naming

| # | Tag | Path | Finding | Proposal |
|---|---|---|---|---|
| S6 | Should | `test/semantics/fixtures/` | There are four sibling layouts that don't line up: `accept/`, `reject/` (assembly), `typed/` (typing accept) and `typing/reject/{bad,lib}/`. `typing/` has only a `reject/` side, and the accepting typing fixture sits beside it with a different name. | Use `fixtures/assembly/{accept,reject}/` and `fixtures/typing/{accept,reject}/`, and name the goldens `assembly.accept.packages`, `assembly.reject.err`, `typing.accept.tst`, `typing.reject.err` and so on. |
| S7 | Nit | `test/semantics/fixtures/reject/noSources/` | It is the only camelCase directory in the tree. | If package names must be camelCase identifiers, add that as a one-line comment in the dune file. Otherwise rename it `no-sources`. |
| S8 | Nit | `test/semantics/fixtures/reject/noSources/README.md`, `accept/app/notes.txt` | Both are fixtures on purpose: a non-`.zn` file that assembly must skip. As names, they look like documentation someone left behind. | Rename them to something that says what they are, for example `not-source.txt`. |

### 9.4 Oversized test files

| # | Tag | Path | Finding | Proposal |
|---|---|---|---|---|
| S9 | Should | `test/ambiguity/cli_test.py` (917 lines) | Nine classes covering three subjects. `ValueParsingTests`, `ProfileTests` and `OutputPatternTests` test **`profiles.py`**. `CommandLineTests`, `SurveyFlagTests` and `StreamingOutputTests` test **`cli.py`/`runner.py`**. `TerminalClassEngineTests`, `MinTokenEngineTests` and `PartitionBudgetEngineTests` test the **OCaml engine**. | Split it into `tests/ambiguity/profiles_test.py`, `cli_test.py` and `engine_test.py`, and move the engine tests next to `prover/`. |
| S10 | Nit | `test/parser/syntax_test.py` (808 lines, one class) | One `ParserSyntaxTests` class covers declarations, statements and terminators, imports, maps and match, moulds, and operators. | Split it by the grammar's own areas, or at least into several `TestCase` classes, so a failure report names the area. |

### 9.5 Build files

| # | Tag | Path | Finding | Proposal |
|---|---|---|---|---|
| S11 | Should | `test/codegen/dune` (470 lines) | Fourteen fixtures, each with the same four hand-copied stanzas: `.cgt` → diff → build → run → diff. Adding a fixture means copying 40 lines and editing six places. The copies have already drifted apart: some rules are on one line and some on six, and there are stray double blank lines before `hosts` and `guests`. | Generate the rules. Either a small `gen_rules.ml` writing `dune.inc` (checked in, diffed by `dune build @runtest`), or a cram test per fixture. Keep one comment per fixture as a `README` line or a comment at the top of its `main.zn`. |
| S12 | Nit | `test/parser/dune`, `test/runtime/dune` | The same repetition on a smaller scale: six span rules, five reject rules, five runtime rules. | Same generator. |
| S13 | Should | `justfile` → `test-ambiguity-tools` | The recipe lists eight test modules by hand, so a new test file is silently skipped until someone adds it there. | `python3 -m unittest discover -s tests/ambiguity -p '*_test.py' -t .` |

---

## 10. `docs/`

| # | Tag | Path | Finding | Proposal |
|---|---|---|---|---|
| O1 | Must | `docs/repository-layout.md` | It still says "Status: **proposal**", but it has been carried out. Its "Current pressure points" table lists five paths that no longer exist, and its migration phases describe moves that are done. Anyone who reads it gets a wrong picture of the repo. | Delete it. This document replaces it, and git history keeps the old one. |
| O2 | Must | `docs/ambiguity/research-handoff.md` | It is dated ("As of 2026-09-24"), refers to one draft PR (#106) and specific CI runs, and is written as a hand-off note. That is PR or issue content. Under `docs/`, it reads as if it were current. | Move it into PR #106's description or a tracking issue, and delete the file. |
| O3 | Must | `docs/lowering.md` | "Status: **design**. Stage 4 … follow this design once they are built." Stages 4 and 6 are built, and steps 1–8 of its own §8 have landed (#130–#137). | Update the status line to say which steps are built. |
| O4 | Should | `docs/ambiguity.md` + `docs/ambiguity/` | The index file sits next to its own directory. | Move it to `docs/ambiguity/README.md`. GitHub shows that file when someone opens the directory. |
| O5 | Should | `docs/` (flat) | Six design documents (`stages`, `desugaring`, `semantics`, `lowering`, `generics`, `concepts-vs-primitives`) sit next to a process document (`spec-divergences`), a repository meta document (`repository-layout`) and a subsystem directory (`ambiguity/`). There is no index. | Create `docs/design/` for the six, `docs/README.md` as an index with one line per document, and keep `spec-divergences.md` at the top level, since contributors read it before a spec section. |
| O6 | Nit | `docs/semantics.md`, `docs/lowering.md` | The file names are stage names, but the titles are "Designing the TST" and "Designing the CGT". | Choose one pattern: rename the files to `tst.md`/`cgt.md`, or retitle them "Semantics"/"Lowering". |
| O7 | Nit | `docs/concepts-vs-primitives.md` (40 lines), `docs/generics.md` (51 lines) | Both are short and each is a follow-on to one section of a larger document (`semantics.md` §4, and D12/L4). | Fine as they are once they are under `design/`. Just make sure the index says which larger document each one belongs to. |

---

## 11. `reports/`

| # | Tag | Finding | Proposal |
|---|---|---|---|
| Q1 | Should | 29 committed text files are raw tool output: 17 prove logs and 12 search logs. Several are from July, before the engine split and the CEGAR work, so their output formats and options no longer match the current tool. Because they are checked in, every refactor has to either keep them readable or leave them as dead weight. | Stop committing run output. The workflows already upload it as artifacts. If a run is worth remembering, write down its *conclusion* in `docs/ambiguity/experiments.md` with a link to the workflow run, and delete `reports/`. |
| Q2 | Nit | If `reports/` stays: `prove/` names files `DATE_slug.txt`, while `search/` names them `PROFILE/DATE_TIME.txt`. | Use one scheme: `DATE_slug` everywhere, because a slug tells you why the run was kept. |

---

## 12. `.github/`

| # | Tag | Path | Finding | Proposal |
|---|---|---|---|---|
| H1 | Should | `.github/agents/implementation-specialist.md` | A cross-repo agent persona: a map of all six `zane-lang` repos, `model: gpt-5.4`, and a formatting policy. Nothing in it is specific to this repo. It tells the agent to "Read `contributing/` first", but this repo has no `contributing/`. | Move it to the organization's `.github` repository, where it applies to every repo. Put this repo's own conventions in a real `CONTRIBUTING.md`, or create the `contributing/` it refers to. |
| H2 | Must | `.github/workflows/copilot-setup-steps.yml` | It installs devbox but never runs `dev/bin/bootstrap-toolchain`, so the environment it sets up has no dune, menhir or sedlex. The one thing the workflow exists for doesn't work. | Add the bootstrap step and the LLVM apt step, matching `ci.yml`. |
| H3 | Should | all workflows | Action pins are inconsistent. `ci.yml` and `copilot-setup-steps.yml` use floating tags (`actions/checkout@v6`, `devbox-install-action@v0.15.0`). `shell.yml` and the ambiguity workflows use SHA pins, and `shell.yml` pins `devbox-install-action` to **v0.14.0** while CI uses v0.15.0. | Pin every action by SHA, at the same version everywhere. A Dependabot `github-actions` entry keeps them current. |
| H4 | Nit | `.github/workflows/ci.yml` | It checks out with `submodules: recursive`, but the repo has no `.gitmodules`. | Remove it, here and in `shell.yml`. |
| H5 | Nit | `.github/scripts/ci-suites` | The path patterns in it will be wrong after any move in this proposal. | Update it in each migration PR, and check that the SHARED list still includes every file that affects the build. |

---

## 13. Migration order

Each step should be its own PR that answers one question: *did this move
change behavior?* Golden files must pass unchanged after every step, except
where a step says otherwise.

1. **Deletions and one-line fixes** (no moves): R4–R9, R11, O1, O2, O3,
   H2, H4, D1. This removes the misleading files before anything else.
2. **Test placement**: A3 (with the `justfile` suite fix), S2, S3, S4, S5,
   S13.
3. **`bin/` rename and default removal**: B1, B2, D2. This updates every
   `%{exe:…/main.exe}` in the test dune files, so do it before S11.
4. **Generate the test dune rules**: S11, S12. After step 3, so the
   generator writes the final paths.
5. **`test/` → `tests/`**: S1, S6, S7, S8. This is a single mechanical
   rename. Update the `justfile` module paths, `ci-suites`, and the
   `parents[N]` root calculations in `harness.py`, `cli_test.py`,
   `syntax_test.py` and `ambiguity_test.py`.
6. **`lib/tst/` subdirectories and pass renames**: T1, T2. Using
   `include_subdirs unqualified` means T1 changes no code, and T2 renames
   two modules.
7. **File splits**, one per PR: T3, G1, C1, A1, U1–U3, S9, S10.
8. **Tool layout**: A2, A4, A5, P1, X1, X2, R2, R1.
9. **Docs reorganization**: O4–O7, R12, and the new `docs/README.md`.
10. **Interfaces**: L1 and L2, one library at a time from the bottom up
    (`source` → `diagnostic` → `tree_graph` → `cst` → …).
11. **Optional**: Q1/Q2, D3, T4, P2, R13, H1, H3.

---

## 14. What should stay as it is

A strict review can end up recommending splits for their own sake. These
files are large or unusual on purpose, and should stay as they are:

- **`lib/cst/nodes.ml`, `lib/sst/nodes.ml`, `lib/tst/nodes.ml`,
  `lib/cgt/nodes.ml`**: one set of mutually recursive types each. Splitting
  them would need recursive modules.
- **`lib/cst/parser.mly`**: one grammar, reviewed as one unit.
- **`lib/sst/lower.ml`** (688 lines): one recursive walk with clear
  internal sections.
- **The recursive core of `check.ml` and `cgt/lower.ml`**: T3 and G1 take
  only the non-recursive parts out. Splitting the walk itself would mean
  replacing `and` chains with recursion across modules.
- **`lib/source/`, `lib/diagnostic/`, `lib/tree_graph/`**: small, focused,
  and in the right direction in the dependency graph.
- **Stage directories named after trees** (L3).
- **`.github/scripts/`**: small scripts that read their inputs from the
  environment because of how `devbox run` quotes arguments. The reason is
  documented in each file.
- **`justfile` as the single entry point** for build and test.
