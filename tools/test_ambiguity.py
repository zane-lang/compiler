#!/usr/bin/env python3
import argparse
import os
import shutil
import subprocess
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from tools import ambiguity

ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / "_build" / "default" / "tools" / "ambiguity_search.exe"

# A minimal grammar whose two atoms A and B are interchangeable (both reduce to
# [e] in the same contexts) so they collapse into one terminal class, while the
# unparenthesized [e PLUS e] rule is genuinely ambiguous. It exercises the
# equivalence-class machinery on a grammar small enough for the prover to finish
# instantly.
TINY_GRAMMAR = """\
%token A "a"
%token B "b"
%token PLUS "+"
%token EOF "<eof>"
%start <unit> main
%%
main: e EOF { () }
e:
  | A { () }
  | B { () }
  | e PLUS e { () }
"""


def engine_environment() -> dict[str, str] | None:
    menhir = os.environ.get("AMBIGUITY_MENHIR") or shutil.which("menhir")
    if not ENGINE.exists() or menhir is None:
        return None
    return {
        **os.environ,
        "AMBIGUITY_MENHIR": menhir,
        "AMBIGUITY_MEMORY_MB": "64",
        "AMBIGUITY_MAX_FRONTIER_RATIO": "1.0",
        "AMBIGUITY_JOBS": "1",
    }


class ValueParsingTests(unittest.TestCase):
    def test_token_range_accepts_whitespace(self) -> None:
        self.assertEqual(ambiguity.parse_token_range(" 12 .. 50 "), (12, 50))

    def test_token_range_rejects_a_descending_range(self) -> None:
        with self.assertRaisesRegex(
            ambiguity.ConfigurationError, "minimum must not exceed"
        ):
            ambiguity.parse_token_range("50..12")

    def test_duration_accepts_friendly_and_composed_units(self) -> None:
        self.assertEqual(ambiguity.parse_duration("1h30m"), 5400)
        self.assertEqual(ambiguity.parse_duration("250ms"), 0.25)
        self.assertEqual(ambiguity.parse_duration(90), 90)

    def test_duration_rejects_trailing_text(self) -> None:
        with self.assertRaisesRegex(ambiguity.ConfigurationError, "invalid duration"):
            ambiguity.parse_duration("30 minutes")


class ProfileTests(unittest.TestCase):
    def write_profiles(self, contents: str) -> Path:
        directory = TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = Path(directory.name) / "searches.toml"
        path.write_text(contents, encoding="utf-8")
        return path

    def test_inheritance_and_overrides(self) -> None:
        path = self.write_profiles(
            """
[profiles.base]
description = "Broad search."
tokens = "0..20"
timeout = "2m"
witnesses = 10

[profiles.deep]
extends = "base"
tokens = "12..50"
prefix_tokens = ["UIDENT", "LCURLY"]
nodes_per_depth = 4
"""
        )
        profile = ambiguity.load_profiles(path)["deep"]
        self.assertEqual(profile.description, "Broad search.")
        self.assertEqual((profile.min_tokens, profile.max_tokens), (12, 50))
        self.assertEqual(profile.timeout_seconds, 120)
        self.assertEqual(profile.prefix_tokens, ("UIDENT", "LCURLY"))
        self.assertEqual(profile.nodes_per_depth, 4)

        arguments = argparse.Namespace(
            token_range="10..30",
            timeout="1h",
            witnesses=25,
            prefix_tokens="UIDENT LIDENT",
            nodes_per_depth=None,
            breadth_first=True,
        )
        overridden = ambiguity.apply_overrides(profile, arguments)
        self.assertEqual((overridden.min_tokens, overridden.max_tokens), (10, 30))
        self.assertEqual(overridden.timeout_seconds, 3600)
        self.assertEqual(overridden.witnesses, 25)
        self.assertEqual(overridden.prefix_tokens, ("UIDENT", "LIDENT"))
        self.assertIsNone(overridden.nodes_per_depth)

    def test_inheritance_cycle_is_reported(self) -> None:
        path = self.write_profiles(
            """
[profiles.one]
extends = "two"

[profiles.two]
extends = "one"
"""
        )
        with self.assertRaisesRegex(
            ambiguity.ConfigurationError, "one -> two -> one"
        ):
            ambiguity.load_profiles(path)

    def test_unknown_setting_is_reported(self) -> None:
        path = self.write_profiles(
            """
[profiles.quick]
tokens = "0..10"
timeout = "1m"
witnesses = 5
surprise = true
"""
        )
        with self.assertRaisesRegex(
            ambiguity.ConfigurationError, "unknown settings: surprise"
        ):
            ambiguity.load_profiles(path)


class OutputPatternTests(unittest.TestCase):
    def test_profile_and_date_placeholders_expand(self) -> None:
        path = ambiguity.expand_output_path(
            Path("reports/{profile}-{date}.txt"), "general"
        )
        self.assertRegex(str(path), r"^reports/general-\d{4}-\d{2}-\d{2}\.txt$")

    def test_timestamp_placeholders_expand(self) -> None:
        path = ambiguity.expand_output_path(
            Path("{profile}_{datetime}--{time}"), "deep"
        )
        self.assertRegex(
            str(path),
            r"^deep_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}--\d{2}-\d{2}-\d{2}$",
        )

    def test_plain_path_is_unchanged(self) -> None:
        self.assertEqual(
            ambiguity.expand_output_path(Path("report.txt"), "general"),
            Path("report.txt"),
        )

    def test_unknown_placeholder_is_reported(self) -> None:
        with self.assertRaisesRegex(
            ambiguity.ConfigurationError, "unknown placeholder"
        ):
            ambiguity.expand_output_path(Path("reports/{oops}.txt"), "general")

    def test_unbalanced_brace_is_reported(self) -> None:
        with self.assertRaisesRegex(
            ambiguity.ConfigurationError, "invalid --output pattern"
        ):
            ambiguity.expand_output_path(Path("reports/{profile.txt"), "general")

    def test_literal_braces_are_preserved(self) -> None:
        self.assertEqual(
            ambiguity.expand_output_path(Path("reports/{{profile}}.txt"), "general"),
            Path("reports/{profile}.txt"),
        )

    def test_indexed_placeholder_is_rejected(self) -> None:
        # str.format_map would silently expand this to the first character.
        with self.assertRaisesRegex(
            ambiguity.ConfigurationError, "unknown placeholder"
        ):
            ambiguity.expand_output_path(Path("{profile[0]}.txt"), "general")

    def test_attribute_placeholder_is_rejected(self) -> None:
        # str.format_map would raise an uncaught AttributeError here.
        with self.assertRaisesRegex(
            ambiguity.ConfigurationError, "unknown placeholder"
        ):
            ambiguity.expand_output_path(Path("{profile.foo}.txt"), "general")

    def test_format_spec_is_rejected(self) -> None:
        with self.assertRaisesRegex(
            ambiguity.ConfigurationError, "no format spec or conversion"
        ):
            ambiguity.expand_output_path(Path("{profile:>10}.txt"), "general")


class CommandLineTests(unittest.TestCase):
    def test_search_defaults_to_general(self) -> None:
        arguments = ambiguity.parser().parse_args(["search"])
        self.assertEqual(arguments.profile, "general")

    def test_prove_defaults_to_quick(self) -> None:
        arguments = ambiguity.parser().parse_args(["prove", "3"])
        self.assertEqual(arguments.profile, "quick")

    def test_check_accepts_quoted_or_individual_tokens(self) -> None:
        cli = ambiguity.parser()
        quoted = cli.parse_args(["check", "UIDENT LPAREN RPAREN EOF"])
        separate = cli.parse_args(
            ["check", "UIDENT", "LPAREN", "RPAREN", "EOF"]
        )
        self.assertEqual(" ".join(quoted.tokens), " ".join(separate.tokens))

    def test_engine_arguments_are_stable_and_low_level(self) -> None:
        profile = ambiguity.SearchProfile(
            name="deep",
            description="",
            min_tokens=12,
            max_tokens=50,
            timeout_seconds=1800,
            witnesses=50,
            prefix_tokens=("UIDENT", "LCURLY"),
            nodes_per_depth=10,
        )
        self.assertEqual(
            ambiguity.engine_arguments(profile),
            [
                "--max-tokens",
                "50",
                "--min-tokens",
                "12",
                "--timeout",
                "1800",
                "--max-witnesses",
                "50",
                "--prefix-tokens",
                "UIDENT LCURLY",
                "--nodes-per-depth",
                "10",
            ],
        )


class TerminalClassEngineTests(unittest.TestCase):
    """End-to-end checks that the search collapses interchangeable terminals
    without losing an ambiguity reachable only through a non-representative
    member. Skipped when the engine binary or menhir is unavailable, so the
    otherwise pure-Python suite still runs without the OCaml toolchain."""

    def setUp(self) -> None:
        self.environment = engine_environment()
        if self.environment is None:
            self.skipTest(
                "requires a built _build/default/tools/ambiguity_search.exe and menhir"
            )
        directory = TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.grammar = Path(directory.name) / "tiny.mly"
        self.grammar.write_text(TINY_GRAMMAR, encoding="utf-8")

    def engine(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        # --timeout only bounds the engine's own search; a process-level timeout
        # keeps a hung binary or menhir from blocking the whole suite.
        return subprocess.run(
            [str(ENGINE), *arguments, str(self.grammar)],
            env=self.environment,
            text=True,
            capture_output=True,
            timeout=120,
        )

    def test_interchangeable_atoms_share_one_class(self) -> None:
        result = self.engine("--dump-terminal-classes")
        self.assertIn("{ A B }", result.stdout)

    def test_ambiguity_holds_through_a_non_representative_member(self) -> None:
        # B is not the class representative (A sorts first), so the search never
        # shifts it directly; the all-B sentence must still be recognized as
        # ambiguous, confirming the representative stands in for the whole class.
        result = self.engine("--check-tokens", "B PLUS B PLUS B EOF")
        self.assertIn("Accepting derivations: 2", result.stdout)
        self.assertEqual(result.returncode, 1)

    def test_prove_finds_the_ambiguity_via_the_representative(self) -> None:
        # prove drives the abstract BFS over class representatives, then
        # concretizes; it must surface the e-PLUS-e ambiguity even though every
        # witness is spelled with the representative atom.
        result = self.engine(
            "--prove", "2",
            "--max-tokens", "8",
            "--timeout", "30",
            "--max-witnesses", "5",
        )
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("complete ambiguity", result.stdout)
        # The witness must be spelled with the class representative A, never the
        # non-representative B, confirming concretization stays on representatives.
        witnesses = [
            line for line in result.stdout.splitlines() if "Tokens (" in line
        ]
        self.assertTrue(witnesses, result.stdout)
        tokens = witnesses[0].split(":", 1)[1].split()
        self.assertIn("A", tokens)
        self.assertNotIn("B", tokens)


if __name__ == "__main__":
    unittest.main()
