#!/usr/bin/env python3
"""Package a native macOS compiler and its non-system dylib closure."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tarfile
import tempfile


RUNTIME_TARGETS = (
    "x86_64-linux-gnu",
    "aarch64-linux-gnu",
    "x86_64-windows-gnu",
    "aarch64-windows-gnu",
    "x86_64-macos",
    "aarch64-macos",
)


def command(*args):
    return subprocess.check_output(args, text=True)


def dependencies(image):
    lines = command("otool", "-L", str(image)).splitlines()[1:]
    result = []
    for line in lines:
        match = re.match(r"\s*(.*?) \(compatibility version ", line)
        if match:
            result.append(match.group(1))
    return result


def rpaths(image):
    lines = command("otool", "-l", str(image)).splitlines()
    result = []
    for index, line in enumerate(lines):
        if line.strip() == "cmd LC_RPATH":
            match = re.match(r"\s*path (.*?) \(offset ", lines[index + 2])
            if match:
                result.append(match.group(1))
    return result


def is_system_path(path):
    return path.startswith(("/System/Library/", "/usr/lib/"))


def set_rpath(image, path):
    for old_path in rpaths(image):
        subprocess.run(["install_name_tool", "-delete_rpath", old_path, str(image)], check=True)
    subprocess.run(["install_name_tool", "-add_rpath", path, str(image)], check=True)


def expand_path(name, loader, executable_dir, search_paths):
    if name.startswith("@loader_path/"):
        candidates = [loader.parent / name.removeprefix("@loader_path/")]
    elif name.startswith("@executable_path/"):
        candidates = [executable_dir / name.removeprefix("@executable_path/")]
    elif name.startswith("@rpath/"):
        suffix = name.removeprefix("@rpath/")
        candidates = []
        for path in search_paths:
            if path.startswith("@loader_path/"):
                base = loader.parent / path.removeprefix("@loader_path/")
            elif path.startswith("@executable_path/"):
                base = executable_dir / path.removeprefix("@executable_path/")
            else:
                base = Path(path)
            candidates.append(base / suffix)
    elif name.startswith("/"):
        candidates = [Path(name)]
    else:
        raise ValueError(f"unsupported dylib install name {name!r} in {loader}")

    for candidate in candidates:
        if candidate.is_file():
            return candidate.resolve()
    raise ValueError(f"cannot resolve dylib {name!r} required by {loader}")


def dylib_name(path, used_names):
    name = path.name
    previous = used_names.get(name)
    if previous is None or previous == path:
        used_names[name] = path
        return name
    digest = hashlib.sha256(str(path).encode()).hexdigest()[:10]
    stem, suffix = os.path.splitext(name)
    unique = f"{stem}-{digest}{suffix}"
    used_names[unique] = path
    return unique


def collect_closure(images):
    """Return dylibs and each image's resolved dependency edges."""
    libraries = {}
    used_names = {}
    edges = {}
    contexts = {}
    pending = [(image, image.parent) for image in images]
    visited = set()
    while pending:
        image, executable_dir = pending.pop()
        image = image.resolve(strict=True)
        key = (image, executable_dir)
        if key in visited:
            continue
        visited.add(key)
        contexts.setdefault(image, executable_dir)
        image_rpaths = rpaths(image)
        image_edges = []
        for name in dependencies(image):
            if is_system_path(name):
                image_edges.append((name, None))
                continue
            source = expand_path(name, image, executable_dir, image_rpaths)
            image_edges.append((name, source))
            if source not in libraries:
                libraries[source] = dylib_name(source, used_names)
                pending.append((source, executable_dir))
        edges[key] = image_edges
    return libraries, edges, contexts


def package(binary, zig, zig_manifest, output, version, commit):
    if not re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        raise ValueError("version must be vMAJOR.MINOR, without leading zeroes")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("commit must be a full Git SHA")
    if platform.system() != "Darwin":
        raise ValueError("package-macos.py must run on macOS")

    binary, zig = binary.resolve(strict=True), zig.resolve(strict=True)
    zig_manifest = zig_manifest.resolve(strict=True)
    zig_description = json.loads(zig_manifest.read_text())
    if not all(key in zig_description for key in ("version", "url", "sha256")):
        raise ValueError("Zig manifest must contain version, url and sha256")
    if not (zig.parent / "lib").is_dir() or not (zig.parent / "LICENSE").is_file():
        raise ValueError("Zig must be from its standalone distribution, with lib/ and LICENSE beside it")

    arch = platform.machine()
    arch = {"arm64": "aarch64", "aarch64": "aarch64", "x86_64": "x86_64"}.get(arch)
    if arch is None:
        raise ValueError(f"unsupported macOS architecture {platform.machine()!r}")
    binary_arches = command("lipo", "-archs", str(binary)).split()
    zig_arches = command("lipo", "-archs", str(zig)).split()
    expected_arch = "arm64" if arch == "aarch64" else "x86_64"
    if expected_arch not in binary_arches:
        raise ValueError(f"compiler architecture {binary_arches} does not include {expected_arch}")
    if expected_arch not in zig_arches:
        raise ValueError(f"Zig architecture {zig_arches} does not include {expected_arch}")

    with tempfile.TemporaryDirectory(prefix="zane-release-") as temporary:
        root = Path(temporary) / f"zane-compiler-{version}-macos-{arch}"
        for directory in ("bin", "lib", "libexec", "share", "zig"):
            (root / directory).mkdir(parents=True)
        compiler = root / "libexec/zanec"
        zig_binary = root / "zig/zig"
        shutil.copy2(binary, compiler)
        shutil.copy2(zig, zig_binary)
        shutil.copy2(zig.parent / "LICENSE", root / "zig/LICENSE")
        shutil.copytree(zig.parent / "lib", root / "zig/lib")

        # macOS exposes temporary directories through aliases such as /var ->
        # /private/var. Keep the image paths in the same canonical form that
        # collect_closure uses for its edge and context keys.
        images = [compiler.resolve(strict=True), zig_binary.resolve(strict=True)]
        libraries, edges, contexts = collect_closure(images)
        for source, name in libraries.items():
            shutil.copy2(source, root / "lib" / name)

        source_to_copy = {source: root / "lib" / name for source, name in libraries.items()}
        for original in images + list(libraries):
            copied = original if original in images else source_to_copy[original]
            process_dir = contexts[original]
            for name, dependency in edges[(original, process_dir)]:
                if dependency is not None:
                    subprocess.run(
                        ["install_name_tool", "-change", name,
                         f"@rpath/{libraries[dependency]}", str(copied)],
                        check=True,
                    )
            if original in libraries:
                subprocess.run(
                    ["install_name_tool", "-id", f"@rpath/{libraries[original]}", str(copied)],
                    check=True,
                )
                set_rpath(copied, "@loader_path")
        set_rpath(compiler, "@executable_path/../lib")
        set_rpath(zig_binary, "@executable_path/../lib")

        project = Path(__file__).resolve().parents[2]
        shutil.copy2(project / "LICENSE", root / "share/LICENSE")
        shutil.copy2(project / "dev/release/THIRD_PARTY.md", root / "share/THIRD_PARTY.md")
        shutil.copytree(project / "dev/release/licenses", root / "share/licenses")
        shutil.copy2(project / "devbox.lock", root / "share/devbox.lock")
        shutil.copy2(zig_manifest, root / "share/zig.json")
        (root / "VERSION").write_text(version + "\n")
        (root / "toolchain.coda").write_text(
            f"url https://github.com/zane-lang/compiler\ncommit {commit}\n"
        )
        (root / "bin/zanec").write_text('''#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
unset DYLD_LIBRARY_PATH
unset ZANE_RUNTIME_OBJECTS
if [ "${ZANE_CC+x}" != x ]; then
    ZANE_CC="$root/bin/zig-cc"
    export ZANE_CC
    if [ "${ZIG+x}" != x ]; then
        ZANE_RUNTIME_OBJECTS="$root/share/runtime"
        export ZANE_RUNTIME_OBJECTS
    fi
fi
exec "$root/libexec/zanec" "$@"
''')
        (root / "bin/zig-cc").write_text('''#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec "${ZIG:-$root/zig/zig}" cc "$@"
''')
        for name in ("zanec", "zig-cc"):
            (root / "bin" / name).chmod(0o755)

        environment = {k: v for k, v in os.environ.items() if k not in ("ZANE_CC", "ZIG")}
        environment["ZANE_BITCODE_CC"] = str(Path(__file__).resolve().parent / "bitcode-cc")
        for target in RUNTIME_TARGETS:
            for optimize in ([], ["--optimize"]):
                subprocess.run(
                    [str(root / "bin/zanec"), "--bundle-runtime", str(root / "share/runtime"),
                     "--target", target, *optimize],
                    env=environment,
                    check=True,
                )

        output.mkdir(parents=True, exist_ok=True)
        archive = output / (root.name + ".tar.gz")
        with tarfile.open(archive, "w:gz") as tar:
            tar.add(root, arcname=root.name)
        return archive


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
