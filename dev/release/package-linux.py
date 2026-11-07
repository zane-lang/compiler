#!/usr/bin/env python3
"""Package the native compiler's ELF closure, without a dependency on the environment that built it."""
import argparse
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

import common


def command(*args):
    return subprocess.check_output(args, text=True)


def package(binary, zig, zig_manifest, output, version, commit):
    common.check_label(version, commit)
    binary, zig = binary.resolve(strict=True), common.check_zig(zig)
    zig_manifest = zig_manifest.resolve(strict=True)
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
        root = common.make_root(temporary, version, "linux-x86_64")
        (root / "libexec").mkdir()
        (root / "lib").mkdir()
        shutil.copy2(binary, root / "libexec/zanec")
        shutil.copy2(loader, root / "lib/ld-linux-x86-64.so.2")
        for name, path in libraries:
            shutil.copy2(path, root / "lib" / name)
        common.add_toolchain(root, zig, zig_manifest, version, commit)
        (root / "share/runtime-libraries.txt").write_text(listing)
        # Invoke the bundled loader directly: the binary's interpreter and
        # RUNPATH still name the build environment's paths, which do not exist
        # on a user's host. The loader is the executable the compiler sees,
        # in lib/, so it finds the toolchain one directory above as it does
        # from bin/ on the other platforms.
        # --library-path is local to this process, so system sh and zig do not
        # inherit an LD_LIBRARY_PATH containing a different libc.
        wrapper = root / "bin/zanec"
        wrapper.write_text('''#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
unset LD_LIBRARY_PATH
exec "$root/lib/ld-linux-x86-64.so.2" --library-path "$root/lib" "$root/libexec/zanec" "$@"
''')
        wrapper.chmod(0o755)
        common.bundle_runtimes(root, [str(wrapper)])
        return common.write_archive(root, output)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--zig", type=Path, required=True)
    parser.add_argument("--zig-manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--commit", required=True)
    args = parser.parse_args()
    print(package(args.binary, args.zig, args.zig_manifest, args.output, args.version, args.commit))
