#!/usr/bin/env python3
"""Package the native compiler's ELF closure, without a Nix runtime dependency."""
import argparse
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile


def command(*args):
    return subprocess.check_output(args, text=True)


def package(binary, zig, output, version, commit):
    if not re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        raise ValueError("version must be vMAJOR.MINOR, without leading zeroes")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("commit must be a full Git SHA")
    binary, zig = binary.resolve(strict=True), zig.resolve(strict=True)
    # Releases use the verified standalone distribution from install-zig.
    # Reject other layouts instead of copying a system bin directory.
    if not (zig.parent / "lib").is_dir() or not (zig.parent / "LICENSE").is_file():
        raise ValueError("Zig must be from its standalone distribution, with lib/ and LICENSE beside it")
    headers = command("readelf", "-l", str(binary))
    match = re.search(r"Requesting program interpreter: ([^\]]+)", headers)
    if not match:
        raise ValueError("compiler must be a dynamically linked Linux executable")
    loader = Path(match[1])
    listing = command(str(loader), "--list", str(binary))
    if "not found" in listing:
        raise ValueError("compiler has unresolved shared libraries")
    libraries = re.findall(r"^\s*(\S+) => (/\S+) \(", listing, re.MULTILINE)
    if not libraries:
        raise ValueError("compiler has no resolved shared libraries")

    with tempfile.TemporaryDirectory(prefix="zane-release-") as temporary:
        root = Path(temporary) / f"zane-compiler-{version}-linux-x86_64"
        for directory in ("bin", "lib", "libexec", "share"):
            (root / directory).mkdir(parents=True)
        shutil.copy2(binary, root / "libexec/zanec")
        shutil.copy2(loader, root / "lib/ld-linux-x86-64.so.2")
        for name, path in libraries:
            shutil.copy2(path, root / "lib" / name)
        # Keep Zig's libraries beside its executable; zig cc finds them there.
        (root / "zig").mkdir()
        shutil.copy2(zig, root / "zig/zig")
        shutil.copy2(zig.parent / "LICENSE", root / "zig/LICENSE")
        shutil.copytree(zig.parent / "lib", root / "zig/lib")
        project = Path(__file__).resolve().parents[2]
        shutil.copy2(project / "LICENSE", root / "share/LICENSE")
        shutil.copy2(project / "dev/release/THIRD_PARTY.md", root / "share/THIRD_PARTY.md")
        shutil.copytree(project / "dev/release/licenses", root / "share/licenses")
        shutil.copy2(project / "devbox.lock", root / "share/devbox.lock")
        (root / "share/runtime-libraries.txt").write_text(listing)
        (root / "VERSION").write_text(version + "\n")
        (root / "toolchain.coda").write_text(
            f"url https://github.com/zane-lang/compiler\ncommit {commit}\n"
        )
        # Invoke the bundled loader directly: the binary's interpreter and
        # RUNPATH still name Nix paths, which do not exist on a user's host.
        # --library-path is local to this process, so system sh and zig do not
        # inherit an LD_LIBRARY_PATH containing a different libc.
        (root / "bin/zanec").write_text('''#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
unset LD_LIBRARY_PATH
if [ "${ZANE_CC+x}" != x ]; then
    ZANE_CC="$root/bin/zig-cc"
    export ZANE_CC
fi
exec "$root/lib/ld-linux-x86-64.so.2" --library-path "$root/lib" "$root/libexec/zanec" "$@"
''')
        (root / "bin/zig-cc").write_text('''#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec "${ZIG:-$root/zig/zig}" cc "$@"
''')
        for name in ("zanec", "zig-cc"):
            (root / "bin" / name).chmod(0o755)
        output.mkdir(parents=True, exist_ok=True)
        archive = output / (root.name + ".tar.gz")
        with tarfile.open(archive, "w:gz") as tar:
            tar.add(root, arcname=root.name)
        return archive


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--zig", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--commit", required=True)
    args = parser.parse_args()
    print(package(args.binary, args.zig, args.output, args.version, args.commit))
