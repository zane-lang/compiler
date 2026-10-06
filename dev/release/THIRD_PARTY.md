# Bundled components

The compiler is GPL-3.0-only; `LICENSE` contains its license. Its source is
the commit in `toolchain.coda`, available from
https://github.com/zane-lang/compiler. The committed Devbox lock and OCaml
bootstrap pins describe how it was built.

The archive also includes:

- LLVM 19 (Apache-2.0 with LLVM exceptions):
  https://github.com/llvm/llvm-project/tree/llvmorg-19.1.7
- OCaml's native runtime (LGPL-2.1 with the OCaml linking exception):
  https://github.com/ocaml/ocaml
- The ELF loader and shared libraries resolved by the build. The accompanying
  `runtime-libraries.txt` identifies their exact Nix store builds. Nixpkgs
  recipes and source references are pinned by the compiler's `devbox.lock`:
  https://github.com/NixOS/nixpkgs
  These include glibc (LGPL-2.1-or-later), GCC runtime libraries (GPL-3.0 with
  the GCC runtime library exception), and LLVM's library dependencies.
- Zig 0.16.0 and its C toolchain libraries. Zig's `LICENSE` and the licenses
  in its `lib/` directory are retained with the distribution:
  https://ziglang.org/download/0.16.0/

The bundled loader and libraries can be replaced in `lib/`; the wrapper in
`bin/zanec` uses that directory. `ZANE_CC` selects a replacement C compiler
wrapper, and `ZIG` selects a replacement Zig executable.
