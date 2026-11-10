{
  description = "Compiler and CLI for the Zane programming language";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # vendor/coda is a Git submodule, which a flake's source tree does not
    # include. Pin the revision the repository pins and copy it into place
    # before the build (see `postPatch` below).
    coda = {
      url = "git+https://github.com/zane-lang/coda?rev=0cbeb71bc88b3c8161a8ef5dcff92de0fd294dc4";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      coda,
    }:
    let
      # nixpkgs' unstable branch no longer builds for x86_64-darwin.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      perSystem =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          let
            pkgs = import nixpkgs { inherit system; };
            inherit (pkgs) lib;

            ocamlPackages = pkgs.ocamlPackages;
            llvm = pkgs.llvmPackages_21;

            # LLVM 21 is what the compiler builds against (lib/llvm/config/
            # discover.ml). Nix splits LLVM, clang and LLD into separate
            # outputs and packages, while the build expects one prefix with
            # `bin/ld.lld`, clang's headers and libraries, and LLD's archives
            # beside `llvm-config`. Merge them into the layout it expects.
            llvmPrefix = pkgs.symlinkJoin {
              name = "llvm-21-combined";
              paths = [
                llvm.llvm.out
                llvm.llvm.dev
                llvm.llvm.lib
                llvm.clang-unwrapped
                llvm.clang-unwrapped.dev
                llvm.clang-unwrapped.lib
                llvm.lld
                llvm.lld.dev
                llvm.lld.lib
              ];
            };

            # `ZANE_CC` is the C compiler that compiles the runtime and links
            # programs. On Linux, naming clang with LLD lets `zanec` link
            # in-process with the LLD it is built with (lib/codegen/build.ml);
            # elsewhere clang's own linker is kept, as dev/bin/clang-lld does.
            clangLld = pkgs.writeShellScriptBin "clang-lld" (
              if pkgs.stdenv.hostPlatform.isLinux then
                ''
                  for argument in "$@"; do
                    if [ "$argument" = -c ]; then
                      exec ${llvm.clang}/bin/clang "$@"
                    fi
                  done
                  exec ${llvm.clang}/bin/clang -fuse-ld=lld "$@"
                ''
              else
                ''
                  exec ${llvm.clang}/bin/clang "$@"
                ''
            );

            version = "unstable-${self.shortRev or "dirty"}";

            zanec = ocamlPackages.buildDunePackage {
              pname = "zane-compiler";
              inherit version;
              src = self;

              # dune-project asks for menhir >= 20260122 for its GLR support;
              # nixpkgs' menhir and menhirGLR are the same newer release line.
              buildInputs =
                with ocamlPackages;
                [
                  menhir
                  menhirLib
                  menhirGLR
                  sedlex
                  uucp
                  uuseg
                ]
                ++ [
                  # `zanec` links against LLVM, clang and LLD from this
                  # prefix, so it belongs in buildInputs: the fixup phase
                  # adds its library directory to the binaries' RPATH.
                  llvmPrefix
                  pkgs.libxml2
                  pkgs.zlib
                  pkgs.zstd
                ];

              nativeBuildInputs = [
                ocamlPackages.menhir
                llvmPrefix
                pkgs.pkg-config
                pkgs.makeWrapper
              ];

              LLVM_CONFIG = "${llvmPrefix}/bin/llvm-config";

              # A flake does not fetch submodules. lib/coda builds from
              # vendor/coda, so put the pinned revision there.
              postPatch = ''
                rm -rf vendor/coda
                cp -r ${coda} vendor/coda
                chmod -R u+w vendor/coda
              '';

              # The binaries need clang and LLD at run time, to compile the
              # runtime and link the programs `zanec` builds.
              postInstall = ''
                wrapProgram $out/bin/zanec \
                  --prefix PATH : ${
                    lib.makeBinPath [
                      llvm.clang
                      llvm.lld
                    ]
                  } \
                  --set-default ZANE_CC ${clangLld}/bin/clang-lld
              '';

              doCheck = false;

              meta = {
                description = "Compiler and CLI for the Zane programming language";
                homepage = "https://github.com/zane-lang/compiler";
                license = lib.licenses.gpl3Only;
                mainProgram = "zanec";
                platforms = lib.platforms.unix;
              };
            };
          in
          f {
            inherit
              pkgs
              lib
              ocamlPackages
              llvm
              llvmPrefix
              clangLld
              version
              zanec
              ;
          }
        );
    in
    {
      packages = perSystem (
        { zanec, ... }: {
          inherit zanec;
          default = zanec;
        }
      );

      checks = perSystem (
        { zanec, ... }: {
          default = zanec;
        }
      );

      devShells = perSystem (
        {
          pkgs,
          ocamlPackages,
          llvm,
          llvmPrefix,
          clangLld,
          zanec,
          ...
        }:
        {
          default = pkgs.mkShell {
            inputsFrom = [ zanec ];

            packages =
              with ocamlPackages;
              [
                ocaml
                dune_3
                menhir
                menhirLib
                menhirGLR
                sedlex
                uucp
                uuseg
              ]
              ++ [
                llvmPrefix
                llvm.clang
                llvm.lld
                pkgs.pkg-config
                pkgs.just
                pkgs.python3
                pkgs.nodejs
                pkgs.zlib
                pkgs.zstd
                pkgs.libxml2
              ];

            LLVM_CONFIG = "${llvmPrefix}/bin/llvm-config";
            ZANE_CC = "${clangLld}/bin/clang-lld";
            AR = "llvm-ar";
            STRIP = "llvm-strip";
          };
        }
      );

      formatter = perSystem ({ pkgs, ... }: pkgs.nixfmt);
    };
}
