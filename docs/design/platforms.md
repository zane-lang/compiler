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
    test expects, and run with the arguments its fixture lists.
    `just test-windows` runs the same programs under Wine.
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

## Every thread has 8 MiB of machine stack

A program's main thread has 8 MiB of machine stack on Linux and macOS, and a
Windows program is linked to have the same. The pool's threads are started
with 8 MiB too, where systems give a thread they start anything from
512 KiB (macOS) to 8 MiB (glibc). So a program nests as deeply on every
platform, and on every thread, before it stops with "recursion too deep"
([`lowering.md`](lowering.md) §9).

On POSIX systems the runtime's fault handler runs on a stack of its own,
since one that overflowed leaves none, and finds the thread's stack with
`pthread_getattr_np`, or `pthread_get_stackaddr_np` on macOS. A protection
fault is SIGSEGV on Linux and SIGBUS on macOS, so both are handled.

## What a Windows build uses

A Windows program links with MinGW's C library and its POSIX threads,
winpthreads, both of which `zig cc` carries; `ZANE_CC=dev/bin/zig-cc` links
with it ([`lowering.md`](lowering.md) §7). The runtime differs there in five
places, each marked `_WIN32`: a chunk comes from `_aligned_malloc` and goes
back through `_aligned_free`, a context's range of frames is reserved with
`VirtualAlloc(MEM_RESERVE)` and made usable with `MEM_COMMIT` from a
vectored exception handler, which also reports a full machine stack
(`EXCEPTION_STACK_OVERFLOW`), winpthreads counts the processors, stdout
and stderr are set to binary mode, so a program writes `\n` and not `\r\n`,
as it does everywhere else, and the program's arguments are read from
`GetCommandLineW` through `CommandLineToArgvW` and converted from UTF-16 to
UTF-8 (effects.md §6.6), which links the program with shell32. The program
is linked with `--stack` for an 8 MiB main thread, where the linker would
give it 1 MiB. Scalar float
formatting and `parseF64` also use explicit C numeric-locale CRT calls; POSIX
temporarily selects that locale on the calling thread. Both leave the host's
locale intact.

A target is spelled as `zig cc` reads it, such as `x86_64-windows-gnu`. The
compiler hands LLVM that triple's normal form, `x86_64-unknown-windows-gnu`,
and the C compiler the triple as written.
