"""What every platform's release archive holds and how it is made, for the
packagers beside this file (package-linux.py, package-macos.py,
package-windows.py), which add only the compiler and the libraries it loads.

An archive is `zane-compiler-VERSION-PLATFORM/`, holding:

- `bin/`: the compiler, as `zanec` (`zanec.exe` on Windows, with the DLLs
  it loads beside it; on Linux a wrapper that runs `libexec/zanec` with the
  bundled loader and the libraries in `lib/`, on macOS with the dylibs in
  `lib/`), and `zig-cc`
  (`zig-cc.cmd`), the C compiler a build links with. A compiler finds both
  itself, from `toolchain.coda` one directory above it (lib/codegen/build.ml,
  `released`).
- `zig/`: the standalone Zig release the platform's manifest pins, with its
  `lib/` and `LICENSE`.
- `share/`: the licenses, the lock of the environment it was built in, the
  Zig manifest, and `runtime/`, each target's runtime and link, compiled by
  that Zig (docs/design/lowering.md §7).
- `VERSION` and `toolchain.coda`, which the `zane` CLI checks against the
  release it downloaded.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile


PROJECT = Path(__file__).resolve().parents[2]

# The targets whose runtime a release bundles, compiled once by its own Zig
# for a build with and without optimizing, with the linker command and files
# that link a program with it, so a build for one runs no C compiler
# (docs/design/lowering.md §7).
RUNTIME_TARGETS = (
    "x86_64-linux-gnu",
    "aarch64-linux-gnu",
    "x86_64-windows-gnu",
    "aarch64-windows-gnu",
    "x86_64-macos",
    "aarch64-macos",
)

WINDOWS = sys.platform == "win32"


def check_label(version, commit):
    """Refuse a version or commit that cannot name a release, before any file
    is read."""
    if not re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        raise ValueError("version must be vMAJOR.MINOR, without leading zeroes")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("commit must be a full Git SHA")


def check_zig(zig):
    """`zig`, resolved, refused unless it is from Zig's standalone
    distribution (.github/scripts/install-zig) rather than a system's bin."""
    zig = zig.resolve(strict=True)
    if not (zig.parent / "lib").is_dir() or not (zig.parent / "LICENSE").is_file():
        raise ValueError("Zig must be from its standalone distribution, with lib/ and LICENSE beside it")
    return zig


def make_root(directory, version, platform_name):
    root = Path(directory) / f"zane-compiler-{version}-{platform_name}"
    for name in ("bin", "share", "zig"):
        (root / name).mkdir(parents=True, exist_ok=True)
    return root


def add_toolchain(root, zig, zig_manifest, version, commit):
    """Everything but the compiler and its libraries: Zig, `zig-cc`, the
    licenses and the records."""
    shutil.copy2(zig, root / "zig" / zig.name)
    shutil.copy2(zig.parent / "LICENSE", root / "zig/LICENSE")
    shutil.copytree(zig.parent / "lib", root / "zig/lib")
    shutil.copy2(PROJECT / "LICENSE", root / "share/LICENSE")
    shutil.copy2(PROJECT / "dev/release/THIRD_PARTY.md", root / "share/THIRD_PARTY.md")
    shutil.copytree(PROJECT / "dev/release/licenses", root / "share/licenses")
    shutil.copy2(PROJECT / "pixi.lock", root / "share/pixi.lock")
    shutil.copy2(zig_manifest, root / "share/zig.json")
    (root / "VERSION").write_text(version + "\n")
    (root / "toolchain.coda").write_text(f"url https://github.com/zane-lang/compiler\ncommit {commit}\n")
    if WINDOWS:
        # The compiler runs its C compiler through cmd.exe there.
        (root / "bin/zig-cc.cmd").write_text(
            "@echo off\r\n"
            "rem `zig cc` as one command: the bundled Zig, or the one ZIG names.\r\n"
            'if defined ZIG ("%ZIG%" cc %*) else ("%~dp0..\\zig\\zig.exe" cc %*)\r\n'
        )
    else:
        zig_cc = root / "bin/zig-cc"
        zig_cc.write_text(
            "#!/bin/sh\n"
            "# `zig cc` as one command: the bundled Zig, or the one ZIG names.\n"
            "set -eu\n"
            'root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)\n'
            'exec "${ZIG:-$root/zig/zig}" cc "$@"\n'
        )
        zig_cc.chmod(0o755)


def bitcode_cc():
    """The C compiler the runtimes' bitcode is compiled with
    (`ZANE_BITCODE_CC`): bitcode-cc beside this file, through cmd.exe on
    Windows, which cannot run it alone."""
    here = Path(__file__).resolve().parent
    return str(here / ("bitcode-cc.cmd" if WINDOWS else "bitcode-cc"))


def bundle_runtimes(root, compiler):
    """Each target's runtime and link, compiled by running *compiler*, the
    archive's own, with the bundled `zig cc` and Zig and none of the build
    environment's. `ZANE_CC` names it, so bitcode-cc reads the same, and so
    no runtime is taken from the bundle being made. Their bitcode is
    compiled by the environment's clang, of the LLVM version zanec reads,
    with the headers Zig compiles each target with (bitcode-cc)."""
    environment = {k: v for k, v in os.environ.items() if k not in ("ZIG", "ZANE_RUNTIME_OBJECTS")}
    environment["ZANE_CC"] = str(root / "bin" / ("zig-cc.cmd" if WINDOWS else "zig-cc"))
    environment["ZANE_BITCODE_CC"] = bitcode_cc()
    for target in RUNTIME_TARGETS:
        for optimize in ([], ["--optimize"]):
            subprocess.run(
                [*compiler, "--bundle-runtime", str(root / "share/runtime"), "--target", target, *optimize],
                env=environment, check=True,
            )


def write_archive(root, output):
    output.mkdir(parents=True, exist_ok=True)
    archive = output / (root.name + ".tar.gz")
    with tarfile.open(archive, "w:gz") as tar:
        tar.add(root, arcname=root.name)
    return archive
