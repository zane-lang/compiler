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
  as Windows ones are, and the released toolchain's programs for both its
  architectures are run on macOS in CI.

## 64-bit targets only

The compiler builds for 64-bit targets only. Lowering lays out every type
for a target whose pointers are 8 bytes and which aligns `i64` and `double`
to 8 bytes, as C lays out a struct there: a handle is 24 bytes, a sum's
payload starts at offset 8, and a scope's record and a spawned call's header
are 224 and 96 bytes (`lib/cgt/nodes.ml`, `runtime/zane_abi.h`). Every
offset and size of the runtime's records that emitted code relies on is
written once, in `runtime/zane_abi.h`: `runtime/zane_internal.h` asserts
each against the structs, and codegen reads them from it as `Abi`
(`lib/codegen/dune`). `tests/runtime/abi/probe.c` prints what the structs
measure; the unit tests hold it to `Abi` on Linux, and
`dev/bin/windows-programs` holds it to the header on Windows. On a target with 4-byte pointers, such as
`i386-unknown-linux-gnu` or `armv7-unknown-linux-gnueabihf`, those offsets
would disagree with what LLVM and the C compiler lay out.

So once LLVM has made the target machine, `Build.target_machine`
(`lib/codegen/build.ml`) reads its data layout and refuses the target
unless the pointer size is 8 and the ABI alignment of `i64` and of `double`
is 8. The refusal is an error before anything is emitted: "the target
`i386-unknown-linux-gnu` has 4-byte pointers; this compiler builds for
64-bit targets only". Byte order is not part of the check, since nothing
depends on it: every value is read at the width it was written, and the
object rewriters read either byte order.

## Building for macOS needs no Apple SDK

Linking for macOS needs the declarations of its C library, `libSystem`, and
nothing else from Apple. Zig carries those itself, as the text stubs
`libSystem.tbd`, which the LLD in the compiler links with
(docs/design/lowering.md §7), so any machine can build a macOS program without
the macOS SDK, whose license allows its use only on Apple hardware.

That holds as long as the compiler, the runtime and the standard library use
only what `libSystem` provides. They keep to it: a feature that would need an
Apple framework, such as a GUI or the GPU, belongs in a package of its own,
built on a Mac by those who want it.

## The C math library

The approximate math functions of `@math$` are the C math library's where
the program runs ([`lowering.md`](lowering.md) L17). Every platform's C
library holds it: `libSystem` on macOS and MinGW's C library on Windows,
which a program links already, and glibc on Linux, where it is a library
of its own and a program is linked with `-lm`. Their results can differ in
the last digit, which the spec allows of an approximate function
([`math.md`](https://github.com/zane-lang/spec/blob/1457830/spec/math.md)
§2.6); the `math` codegen fixture checks them within a tolerance.

## Machine stack sizes

A program's main thread uses the stack its launch environment provides on
Linux and macOS, commonly 8 MiB. On Linux `RLIMIT_STACK`, set through
`ulimit -s`, can make it smaller or larger. A Windows program is linked
with an 8 MiB main stack, and the pool's threads are explicitly started
with 8 MiB on every platform. Recursion depth can therefore differ between
the main thread and workers. A full stack stops the program with
"recursion too deep" ([`lowering.md`](lowering.md) §9).

On POSIX systems the runtime's fault handler runs on a stack of its own,
since one that overflowed leaves none, and finds the thread's stack with
`pthread_getattr_np`, or `pthread_get_stackaddr_np` on macOS. A protection
fault is SIGSEGV on Linux and SIGBUS on macOS, so both are handled.

A stop from the handler first flushes what the program printed, which waits
in the runtime's own buffer ([`lowering.md`](lowering.md) §9), unless
another thread holds the buffer. It never blocks on a full pipe: on Linux
it writes a pipe through a non-blocking descriptor of its own, opened from
`/proc/self/fd/1`, and drops what the pipe cannot take, while macOS drops a
pipe's output and Windows writes only a terminal or a file.

## Address range supported by the runtime

Slots, references and dynamic blocks use native pointers. The current
runtime's chunk map indexes only the low 48 bits of an address: an allocation
at or above `2^48` stops with "memory beyond a 48-bit address". This is an
implementation limit, separate from the size the operating system permits
a process to reserve. It applies to dynamic chunks and the fixed-size range,
including its guard. Supporting higher addresses requires extending the
chunk map; native pointers themselves impose no 32 GiB ceiling.

The same bound limits the size of a type: lowering refuses a type that takes
`2^48` bytes or more where it is named, since no value of it could be
placed ([`lowering.md`](lowering.md) §9). The limit is `Ty.limit` in
`lib/cgt/nodes.ml`, and it rises with the chunk map if the map is extended.

## What a Windows build uses

A Windows program links with MinGW's C library and its POSIX threads,
winpthreads, both of which `zig cc` carries; `ZANE_CC=dev/bin/zig-cc` links
with it ([`lowering.md`](lowering.md) §7). The runtime differs there in five
places, each marked `_WIN32`: a dynamic chunk is carved from a 64 MiB
reservation, decommitted with `VirtualFree(MEM_DECOMMIT)` when it turns
cold, and released with its whole reservation
([`lowering.md`](lowering.md) §9), a context's range of frames and a list's
growing oversized span are reserved with
`VirtualAlloc(MEM_RESERVE)` and made usable with `MEM_COMMIT`, the range
from a vectored exception handler, which also reports a full machine stack
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
