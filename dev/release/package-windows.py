#!/usr/bin/env python3
"""Package a native Windows compiler and the DLLs it loads that are not Windows' own."""
import argparse
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile

import common


# The C and C++ runtime the MSVC build links against. A machine without the
# Visual C++ redistributable lacks them, so they are bundled wherever they
# are found, as Microsoft allows for an application's own directory.
REDISTRIBUTABLE = re.compile(r"(vcruntime|msvcp|concrt|vccorlib)[0-9_]*\.dll", re.IGNORECASE)


def imports(image):
    """The DLLs *image* names in its import tables."""
    listing = subprocess.check_output(["llvm-objdump", "-p", str(image)], text=True)
    return re.findall(r"^\s*DLL Name: (\S+)", listing, re.MULTILINE)


def windows_own(name, found):
    """Whether the DLL *name*, found at *found*, comes with Windows: an API
    set, which only the loader resolves, or one in Windows' directory."""
    if name.lower().startswith(("api-ms-win-", "ext-ms-win-")):
        return True
    if REDISTRIBUTABLE.fullmatch(name):
        return False
    system = Path(os.environ.get("SystemRoot", r"C:\Windows")).resolve()
    return found is not None and system in found.resolve().parents


def find(name, directories):
    for directory in directories:
        candidate = Path(directory) / name
        if candidate.is_file():
            return candidate
    return None


def closure(binary):
    """The DLLs *binary* loads, directly or through another, that Windows
    does not bring, searched for as the loader does: beside the binary,
    then on PATH."""
    directories = [binary.parent, *filter(None, os.environ.get("PATH", "").split(os.pathsep))]
    found, pending, seen = {}, [binary], set()
    while pending:
        image = pending.pop()
        for name in imports(image):
            key = name.lower()
            if key in seen:
                continue
            seen.add(key)
            path = find(name, directories)
            if windows_own(name, path):
                continue
            if path is None:
                raise ValueError(f"cannot find {name}, which {image.name} loads")
            found[key] = path
            pending.append(path)
    return found


def package(binary, zig, zig_manifest, output, version, commit):
    common.check_label(version, commit)
    if platform.system() != "Windows":
        raise ValueError("package-windows.py must run on Windows")
    binary, zig = binary.resolve(strict=True), common.check_zig(zig)
    zig_manifest = zig_manifest.resolve(strict=True)
    libraries = closure(binary)

    with tempfile.TemporaryDirectory(prefix="zane-release-") as temporary:
        root = common.make_root(temporary, version, "windows-x86_64")
        common.add_toolchain(root, zig, zig_manifest, version, commit)
        # The loader looks beside the executable first, so the DLLs it
        # loads sit in bin/ with it, and no PATH of the user's reaches them.
        compiler = root / "bin/zanec.exe"
        shutil.copy2(binary, compiler)
        for path in libraries.values():
            shutil.copy2(path, root / "bin" / path.name)
        (root / "share/runtime-libraries.txt").write_text(
            "".join(f"{path.name} <= {path}\n" for path in sorted(libraries.values(), key=lambda p: p.name.lower()))
        )
        common.bundle_runtimes(root, [str(compiler)])
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
