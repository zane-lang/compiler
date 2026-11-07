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
import tempfile

import common


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
            # An LC_RPATH load command prints as `cmd`, `cmdsize`, then
            # `path`. Skipping one we cannot read would leave its old rpath
            # in the archive, so a different layout is an error.
            path_line = lines[index + 2] if index + 2 < len(lines) else ""
            match = re.match(r"\s*path (.*?) \(offset ", path_line)
            if not match:
                raise ValueError(f"cannot read an LC_RPATH path from otool -l output for {image}")
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
    common.check_label(version, commit)
    if platform.system() != "Darwin":
        raise ValueError("package-macos.py must run on macOS")

    binary, zig = binary.resolve(strict=True), common.check_zig(zig)
    zig_manifest = zig_manifest.resolve(strict=True)
    zig_description = json.loads(zig_manifest.read_text())
    if not all(key in zig_description for key in ("version", "url", "sha256")):
        raise ValueError("Zig manifest must contain version, url and sha256")

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
        root = common.make_root(temporary, version, f"macos-{arch}")
        common.add_toolchain(root, zig, zig_manifest, version, commit)
        (root / "lib").mkdir()
        compiler = root / "bin/zanec"
        zig_binary = root / "zig/zig"
        shutil.copy2(binary, compiler)

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
        # Zig's standalone executable links only the system's libraries, so
        # it is given the bundled directory only when it reaches one there:
        # it has no room in its header for a load command added.
        zig_image = images[1]
        if any(dependency is not None for _, dependency in edges[(zig_image, contexts[zig_image])]):
            set_rpath(zig_binary, "@executable_path/../lib")

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
