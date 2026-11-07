"""What `dev/bin/zanec` hands the compiler, run against a stand-in `dune`.

The wrapper changes to the project root before running zanec through dune, so
it expands each path the caller gives against the caller's directory. These
check that it expands exactly the paths and passes every other argument as
written.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[2]
WRAPPER = PROJECT / "dev/bin/zanec"

# Prints each argument after `--` on a line of its own.
FAKE_DUNE = """#!/usr/bin/env bash
while [[ "$1" != -- ]]; do shift; done
shift
for argument in "$@"; do printf '%s\\n' "$argument"; done
"""


def lexicon_keywords():
    """The word spellings among the lexicon's literal tokens: what the lexer
    reads as a keyword rather than an identifier."""
    lines = (PROJECT / "grammar/lexicon.coda").read_text().splitlines()
    start = lines.index("literal_tokens [") + 2
    words = set()
    for line in lines[start:]:
        if line.startswith("]"):
            break
        fields = line.split()
        if len(fields) > 1 and fields[1].isalpha() and fields[1].islower():
            words.add(fields[1])
    return words


@unittest.skipIf(os.name == "nt", "the wrapper is a bash script; Windows uses zanec.exe")
class WrapperTest(unittest.TestCase):
    def run_wrapper(self, *arguments):
        with tempfile.TemporaryDirectory() as temporary:
            scratch = Path(temporary).resolve()
            bin_dir = scratch / "bin"
            bin_dir.mkdir()
            dune = bin_dir / "dune"
            dune.write_text(FAKE_DUNE)
            dune.chmod(0o755)
            caller = scratch / "caller"
            caller.mkdir()
            env = dict(os.environ, PATH=f"{bin_dir}{os.pathsep}{os.environ['PATH']}")
            result = subprocess.run(
                [str(WRAPPER), *arguments], cwd=caller, env=env, capture_output=True, text=True, check=True
            )
            return caller, result.stdout.splitlines()

    def test_source_files_are_expanded_and_stdin_is_kept(self):
        caller, out = self.run_wrapper("--sst", "src/main.zn")
        self.assertEqual(out, ["--sst", f"{caller}/src/main.zn"])
        _, out = self.run_wrapper("-")
        self.assertEqual(out, ["-"])

    def test_arguments_with_spaces_stay_whole(self):
        caller, out = self.run_wrapper(
            "--build", "out dir/hello.exe", "--package", "hello=path with spaces", "--package", "two words"
        )
        self.assertEqual(out, [
            "--build", f"{caller}/out dir/hello.exe",
            "--package", f"hello={caller}/path with spaces",
            "--package", f"{caller}/two words",
        ])

    def test_package_expands_only_its_directory(self):
        caller, out = self.run_wrapper(
            "--check", "--root",
            "--package", "app=project/bin/app",
            "--package", "v1.0%3f9a1c02b7e4d6a8%gui.opengl=lib/gui/opengl",
            "--package", "lib/core",
            "--package", "/abs/dir",
        )
        self.assertEqual(out, [
            "--check", "--root",
            "--package", f"app={caller}/project/bin/app",
            "--package", f"v1.0%3f9a1c02b7e4d6a8%gui.opengl={caller}/lib/gui/opengl",
            "--package", f"{caller}/lib/core",
            "--package", "/abs/dir",
        ])

    def test_a_prefix_that_is_not_a_package_id_is_part_of_the_directory(self):
        for argument in ("my-project=copy", "odd/a=b", "Upper=dir", "a..b=dir", "v1%a%gui=dir", "%0123456789abcdef%gui=dir"):
            caller, out = self.run_wrapper("--package", argument)
            self.assertEqual(out, ["--package", f"{caller}/{argument}"], argument)

    def test_a_keyword_is_not_a_package_name(self):
        keywords = lexicon_keywords()
        self.assertIn("type", keywords)
        self.assertNotIn("literal", keywords)
        for keyword in sorted(keywords):
            for argument in (f"{keyword}=copy", f"gui.{keyword}=copy"):
                caller, out = self.run_wrapper("--package", argument)
                self.assertEqual(out, ["--package", f"{caller}/{argument}"], argument)
        caller, out = self.run_wrapper("--package", "types=copy")
        self.assertEqual(out, ["--package", f"types={caller}/copy"])

    def test_subpackage_paths_and_underscore_names_are_package_ids(self):
        caller, out = self.run_wrapper("--package", "gui.opengl=lib/gui/opengl", "--package", "_private=lib/_private")
        self.assertEqual(out, [
            "--package", f"gui.opengl={caller}/lib/gui/opengl",
            "--package", f"_private={caller}/lib/_private",
        ])

    def test_option_values_that_are_not_paths_pass_unchanged(self):
        caller, out = self.run_wrapper(
            "--target", "x86_64-windows-gnu",
            "--stamp", "geometry=v1.0%3f9a1c02b7e4d6a8%",
            "--import", "app:geo=geometry",
            "--fixed-region", "1048576",
            "--spawned-fixed-region", "2097152",
            "--build", "out/hello.exe",
            "--link", "objects/geometry.o",
            "--c-hashes", "hashes.coda",
            "--package", "hello=hello",
        )
        self.assertEqual(out, [
            "--target", "x86_64-windows-gnu",
            "--stamp", "geometry=v1.0%3f9a1c02b7e4d6a8%",
            "--import", "app:geo=geometry",
            "--fixed-region", "1048576",
            "--spawned-fixed-region", "2097152",
            "--build", f"{caller}/out/hello.exe",
            "--link", f"{caller}/objects/geometry.o",
            "--c-hashes", f"{caller}/hashes.coda",
            "--package", f"hello={caller}/hello",
        ])

    def test_output_options_expand_their_file(self):
        for option in ("--object", "--tier-up", "--compile-commands"):
            caller, out = self.run_wrapper(option, "out/file", "--package", "p")
            self.assertEqual(out, [option, f"{caller}/out/file", "--package", f"{caller}/p"])

    def test_a_missing_value_is_left_for_zanec_to_report(self):
        caller, out = self.run_wrapper("--build", "--package", "d")
        self.assertEqual(out, ["--build", "--package", f"{caller}/d"])

    def test_rewrite_and_remap_expand_only_their_files(self):
        caller, out = self.run_wrapper("--rewrite", "v1.0%3f9a1c02b7e4d6a8%", "in.o", "out.o")
        self.assertEqual(out, ["--rewrite", "v1.0%3f9a1c02b7e4d6a8%", f"{caller}/in.o", f"{caller}/out.o"])
        caller, out = self.run_wrapper("--remap", "v1%a%", "v2%b%", "in.o", "/tmp/out.o")
        self.assertEqual(out, ["--remap", "v1%a%", "v2%b%", f"{caller}/in.o", "/tmp/out.o"])

    def test_bundle_runtime_expands_its_directory_only(self):
        caller, out = self.run_wrapper("--bundle-runtime", "share/runtime", "--target", "aarch64-macos", "--optimize")
        self.assertEqual(out, ["--bundle-runtime", f"{caller}/share/runtime", "--target", "aarch64-macos", "--optimize"])


if __name__ == "__main__":
    unittest.main()
