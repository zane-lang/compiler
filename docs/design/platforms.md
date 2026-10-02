# Platforms

Which operating systems the compiler builds programs and objects for, how
well each is supported, and what building for one may need. A target is
chosen with `--target` ([`lowering.md`](lowering.md) §7), and one machine
builds for every target.

## Support

- **Linux** is where the compiler is developed and where every test runs,
  building, linking and running programs.
- **Windows** objects are built and rewritten
  ([`separate-compilation.md`](separate-compilation.md) C9), and the tests
  hold them to what the stamped build defines. Linking and running a program
  there is not tested yet; the runtime's threads need a POSIX threads
  library, which MinGW provides.
- **macOS** is a lower tier. Its objects are built and rewritten as Windows
  ones are, and are tested the same way, but they get less attention: a
  problem there may wait.

## Building for macOS needs no Apple SDK

Linking for macOS needs the declarations of its C library, `libSystem`, and
nothing else from Apple. A cross-linker such as `zig cc` carries those
itself, so any machine can build a macOS program without the macOS SDK, whose
license allows its use only on Apple hardware.

That holds as long as the compiler, the runtime and the standard library use
only what `libSystem` provides. They keep to it: a feature that would need an
Apple framework, such as a GUI or the GPU, belongs in a package of its own,
built on a Mac by those who want it.
