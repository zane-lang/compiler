"""Exercise a real ELF archive and wrappers, independent of the OCaml build."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("package_linux", PROJECT / "dev/release/package-linux.py")
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


class PackageTest(unittest.TestCase):
    def test_relocated_archive_and_compiler_overrides(self):
        with tempfile.TemporaryDirectory() as temporary:
            scratch = Path(temporary)
            source = scratch / "compiler.c"
            source.write_text('''#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    printf("%s\\n%s\\n%s\\n", getenv("ZANE_CC"),
        getenv("LD_LIBRARY_PATH") ? "polluted" : "clean", argv[1]);
    return argc == 2 ? 0 : 1;
}
''')
            binary = scratch / "compiler"
            subprocess.run(["gcc", str(source), "-o", str(binary)], check=True)
            zig_dir = scratch / "fake-zig"
            zig_dir.mkdir()
            zig = zig_dir / "zig"
            zig.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
            zig.chmod(0o755)
            (zig_dir / "LICENSE").write_text("test license")
            (zig_dir / "lib").mkdir()
            (zig_dir / "lib/marker").write_text("Zig library")
            (zig_dir / "unrelated-binary").write_text("must not be packaged")
            commit = "a" * 40
            archive = packager.package(binary, zig, scratch / "dist", "v0.1", commit)
            extracted = scratch / "extract"
            with tarfile.open(archive) as tar:
                # This is the archive we just created, never a downloaded one.
                options = {"filter": "data"} if hasattr(tarfile, "data_filter") else {}
                tar.extractall(extracted, **options)
            root = extracted / "zane-compiler-v0.1-linux-x86_64"
            relocated = scratch / "toolchain with spaces"
            root.rename(relocated)
            binary.unlink()
            environment = {**os.environ, "LD_LIBRARY_PATH": "/nonexistent"}
            environment.pop("ZANE_CC", None)
            environment.pop("ZIG", None)
            result = subprocess.check_output(
                [str(relocated / "bin/zanec"), "argument with spaces"], env=environment, text=True
            )
            self.assertEqual(result.splitlines(), [str(relocated / "bin/zig-cc"), "clean", "argument with spaces"])
            environment["ZANE_CC"] = "/custom/compiler with spaces"
            result = subprocess.check_output(
                [str(relocated / "bin/zanec"), "override"], env=environment, text=True
            )
            self.assertEqual(result.splitlines()[0], environment["ZANE_CC"])
            result = subprocess.check_output(
                [str(relocated / "bin/zig-cc"), "--target=x86_64-windows-gnu", "file with spaces.c"],
                env=environment, text=True,
            )
            self.assertEqual(result.splitlines(), ["cc", "--target=x86_64-windows-gnu", "file with spaces.c"])
            environment["ZIG"] = str(relocated / "zig/zig")
            self.assertEqual(subprocess.check_output(
                [str(relocated / "bin/zig-cc"), "custom"], env=environment, text=True
            ), "cc\ncustom\n")
            self.assertEqual((relocated / "toolchain.coda").read_text(),
                f"url https://github.com/zane-lang/compiler\ncommit {commit}\n")
            self.assertTrue((relocated / "zig/LICENSE").is_file())
            self.assertTrue((relocated / "zig/lib/marker").is_file())
            self.assertFalse((relocated / "zig/unrelated-binary").exists())

    def test_non_distribution_zig_layout_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = root / "compiler"
            zig = root / "zig"
            binary.touch()
            zig.touch()
            with self.assertRaisesRegex(ValueError, "standalone distribution"):
                packager.package(binary, zig, root / "dist", "v0.1", "a" * 40)

    def test_invalid_version_or_commit_is_rejected_before_file_access(self):
        for version in ("../v0.1", "v01.0", "v0.1.0", "v0.1;echo bad", "v0.1\n"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                packager.package(Path("missing"), Path("missing"), Path("unused"), version, "a" * 40)
        with self.assertRaises(ValueError):
            packager.package(Path("missing"), Path("missing"), Path("unused"), "v0.1", "main")
