# Platforms

Which operating systems the compiler builds programs and objects for, how
well each is supported, and what building for one may need. A target is
chosen with `--target` ([`lowering.md`](lowering.md) §7), and one machine
builds for every target.

## Support

Two tiers. A first-tier platform is one every change must keep working; a
lower-tier one is built and tested the same way, but gets less attention,
and a problem there may wait.

- **Linux** and **Windows** are the first tier. Both are fully supported by
  `zig cc`, which can link for either from any machine, so building for them
  needs no SDK of their own.
  - On Linux every test runs, building, linking and running programs.
  - On Windows, objects are built and rewritten
    ([`separate-compilation.md`](separate-compilation.md) C9), and the tests
    hold them to what the stamped build defines. Every codegen test program,
    plain and optimized, and a program linked against a dependency's
    prebuilt objects are built for `x86_64-windows-gnu` on Linux, linked by
    `zig cc`, and run on Windows itself in CI, each held to the output its
    test expects. `just test-windows` runs the same programs under Wine.
- **macOS** is the lower tier. Its objects are built, rewritten and tested
  as Windows ones are.

## Building for macOS needs no Apple SDK

Linking for macOS needs the declarations of its C library, `libSystem`, and
nothing else from Apple. A cross-linker such as `zig cc` carries those
itself, so any machine can build a macOS program without the macOS SDK, whose
license allows its use only on Apple hardware.

That holds as long as the compiler, the runtime and the standard library use
only what `libSystem` provides. They keep to it: a feature that would need an
Apple framework, such as a GUI or the GPU, belongs in a package of its own,
built on a Mac by those who want it.

## What a Windows build uses

A Windows program links with MinGW's C library and its POSIX threads,
winpthreads, both of which `zig cc` carries; `ZANE_CC=dev/bin/zig-cc` links
with it ([`lowering.md`](lowering.md) §7). The runtime differs there in three
places, each marked `_WIN32`: a chunk comes from `_aligned_malloc` and goes
back through `_aligned_free`, winpthreads counts the processors, and stdout
and stderr are set to binary mode, so a program writes `\n` and not `\r\n`,
as it does everywhere else.

A target is spelled as `zig cc` reads it, such as `x86_64-windows-gnu`. The
compiler hands LLVM that triple's normal form, `x86_64-unknown-windows-gnu`,
and the C compiler the triple as written.
