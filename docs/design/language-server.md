# The language server

`zanec --lsp` is the compiler's language server: an editor starts it and
talks to it in the Language Server Protocol over the server's standard input
and output. The server answers from the compiler's own front end, parsing,
desugaring and semantics, so an editor shows the same problems a build
reports and resolves each name the way semantics resolves it.

An editor normally starts `zane lsp`, which runs the project's compiler as
`zanec --lsp --zane ZANE` (zane's
[`cli.md`](https://github.com/zane-lang/zane/blob/main/docs/design/cli.md)
§2.8). The Neovim client is the
[`zane-nvim`](https://github.com/zane-lang/zane-nvim) plugin.

The server offers:

| Request | What the server answers |
|---|---|
| Diagnostics | Every problem semantics reports, published as the user types |
| Hover | A name's declaration: a verb's signature, a type's definition, a local's type, with the `///` documentation before the declaration; for an intrinsic, its signatures and its description (D17) |
| Go to definition | Where the name's target is declared, for the overload a call chose |
| Go to type definition | The declaration of a value's type |
| Find references | Every use of the target, across the files and builds of the project |
| Rename | An edit of each use's identifier |
| Document symbols | The declarations of a file, with a type's fields and cases under it |
| Completion | The fields, cases, enum maps and methods after `.` and `:`, the intrinsic namespaces after `@` and their names after `@namespace$`, and the names in scope elsewhere |
| Semantic tokens | The kind of each identifier, which Tree-sitter cannot tell from syntax alone |

The code lives in `lib/language_server/`; semantics records what the server
reads in `lib/tst/model/uses.ml` and `lib/tst/index.ml`.

---

## 1. Decisions

**D1. The server is part of `zanec`.** A program runs it as `zanec --lsp`.
A server in its own binary would carry a second copy of the front end, and
a project pinned to one compiler release would need the server of that same
release; inside `zanec`, the pin that picks the compiler picks the server
too.

**D2. Editors start `zane lsp`.** `zane lsp` finds the compiler of the
project the editor starts it in, as `zane check` does, and runs
`zanec --lsp --zane ZANE` with its standard input and output, `ZANE` being
the path of that `zane`. Outside any project it runs the newest installed
compiler. `zanec --lsp` with no `--zane` also works, for an editor that names
the builds itself (D3).

**D3. A project's builds come from `zane builds`.** For each project the
editor opens, the server runs `zane builds` in the project's root. It prints
the builds `zane check` checks, each with the label `zane check` shows and
the compiler flags it passes. So the server sees a project's packages,
imports and dependencies exactly as a check does, and it reads no manifest
itself. An editor without `zane` can name the builds instead, in the
`initialize` request:

```json
{"initializationOptions": {"builds": [{"label": "bin/app/", "flags": ["--root", "--package", "app=/p/bin/app"]}]}}
```

The server lists a project's builds again when its `zane.coda` or
`zane-lock.coda` changes on disk.

**D4. A file is checked in the first build that holds it.** A build holds a
file when one of its `--package` directories is the file's directory. A
library file appears in the library build and in every program's build, and
the library build comes first, so a library's problems show once. A file
that no build holds, such as a file outside every project, gets its syntax
errors and its document symbols, and nothing that needs semantics.
The server compares directories by their real paths, without symbolic
links, but each URI it sends names a file under the editor's spelling of its
directory. So the editor matches a diagnostic or a location to its document
even when it opened the project through a link, as macOS's `/var` links to
`/private/var`.

**D5. Semantics records each name it resolves.** When the server asks, a
check records every use of a name: its span, its target (a declaration, a
field or case, an enum member, a local, a type parameter, a package or an
intrinsic) and whether the use declares the target. Semantics already
decides what each name means, and the record is taken where it decides, so
the server never resolves a name a second way. A build records nothing, and
pays nothing for the record. The same record holds what a check found where
a completion wrote its placeholder (D8). `Index` turns the record into what
the server reads: a description of each declaration, the type of each field, and the
members and names a completion offers.

**D6. A generic body that nothing instantiates is still answered.**
Semantics checks a generic verb's body once per instance, so a body nothing
calls would have no uses. The check already types such a body once with each
type parameter as an error type, to report its problems; the uses that check
records are the server's for that body.

**D7. A document that does not parse keeps its last parse.** While the user
types, a file is often not valid Zane. Its build then reads the file's last
text that parsed, so every other file keeps its answers, and the document
shows its parse error alone. Each answer about the document moves the spans
of the last parse onto the current text, by the edit between the two texts:
a span before the edit stays, a span after it moves by the edit's length,
and a span inside it has no place in the current text and is dropped.

**D8. Completion writes a placeholder at the cursor.** To learn what may
stand at the cursor, the server writes a placeholder identifier there and
checks the build. When the check reaches the placeholder it records what it
found: after `.`, `:` or `!`, the type of the value before it, which a
method name after `subject:@namespace$` records too; in a type, the type
parameters in scope; elsewhere, the locals in scope and the file's package.
The server offers that type's members, the type parameters with the file's
types, or the locals with the file's declarations and imports. D17 says how
the intrinsic namespaces use what the check records. When the
text with the placeholder does not parse, the server tries again with the
placeholder closed into a statement, and offers nothing when no attempt
parses.

**D9. Positions count UTF-8 bytes when the editor allows.** The protocol
counts a position's character in UTF-16 code units unless the client offers
another encoding. The server chooses UTF-8, which the compiler's spans count,
when the client offers it, and converts each position otherwise.

**D10. One thread reads, and the main thread answers in order.** A reader
thread takes each message off standard input and queues it. The main thread
handles the queued messages in the order they came; before a request it
brings every build the request reads up to date, so an answer always reflects
the edits before it. A burst of edits costs one check, after the last of them.

**D11. The protocol is handled in the server itself.** The server reads and
writes JSON with `yojson` and frames the messages itself; it needs a small
part of the protocol, and a library of the protocol's types would add more
code than the server has.

**D12. C code compiles once per build.** A package's C changes what its
foreign declarations mean, and compiling it takes much longer than a check.
The server compiles a build's C the first time it checks the build, and
again after a `.c` file, a `.h` file or the `c.coda` of one of the build's
packages changes on disk, never on an edit to a Zane file.

**D13. Semantic tokens mark identifiers only.** Tree-sitter highlights
keywords, literals, comments and punctuation from syntax alone. What syntax
cannot show is what an identifier names: a type, a function, a method, a
field, a parameter, a local, an enum member or a package. The server's tokens
mark only those, with `readonly` on a constant and `defaultLibrary` on an
intrinsic.

**D14. Rename edits identifiers the project declares.** A rename edits each
use whose text is the old name, so an import that names the target under
another spelling keeps that spelling. The server refuses to rename:

- an intrinsic, and a declaration of a dependency outside the project;
- a package, which its manifest names;
- `this`, an operator, a subscript, a flip or a constructor without a
  name, which have no identifier of their own (a named constructor, such as
  `Point.zero`, renames like a function);
- to a name of the other case, since an identifier's case marks a type or a
  value (spec `lexical.md` §3);
- while a build's last check failed, or while a use in a file that does not
  parse has no place in the current text, since the edits could miss a use.

A new name that clashes with another declaration is the next check's to
report.

**D15. A problem without a span goes where an editor shows it.** A problem
about a file, such as a file that names the wrong package, goes on the
file's first line. A problem about a directory or about the build's flags
has no file, and goes to the editor as a message.

**D16. The Neovim client is `zane-nvim`.** The plugin configures
`vim.lsp.config("zane")` to run `zane lsp` in the nearest directory above the
file that holds `zane.coda`, and enables it once `zane` is on `PATH`.

**D17. Intrinsics are answered from a table, as declarations are from
source.** An intrinsic has no source, so no `///` comment precedes it.
`Intrinsics` lists the names a program writes in each namespace, with their
signatures, and `Intrinsic_docs` holds a description of each, keyed by its
spelling, as `@math$sqrt`. A hover on an intrinsic shows its signatures, each
with its parameters' names, and that description. A signature shows only the
parameters a call writes: the checker supplies the last parameters of a
worker, of `start` and of `@primitives$ArrayRef.fill`, and no program writes
them. A completion item carries the same signature and description.

Completion reads an intrinsic's place from the text before the cursor: `@`
offers the namespaces, `@namespace$` the namespace's names, and
`@namespace$Type.` the type's named constructors. A name after `:` or `!`
before the `@` is a method's, and the server offers the methods whose subject
takes the value before it: after `!` the `mut` ones, after `:` the others, as
the checker requires. Where the check finds a type at the cursor, the
server offers only types. Only a file of the root package is offered
`@program$`, since only the root package reaches it (spec `effects.md` §6.6);
a file that no build holds is not.
A unit test checks that each intrinsic has a description, and that the table
describes nothing else.

---

## 2. Testing

`tests/lsp/lsp_test.py` starts `zanec --lsp` and drives it with the client in
`tests/lsp/client.py`, against the project in `tests/lsp/fixtures/project/`:
a library package and a program that imports it. The tests give the builds in
the `initialize` request (D3), so they need no `zane`. `just test-compiler`
runs them.
