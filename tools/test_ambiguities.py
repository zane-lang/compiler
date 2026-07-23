#!/usr/bin/env python3
import argparse
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from tools import ambiguities


class ValueParsingTests(unittest.TestCase):
    def test_token_range_accepts_whitespace(self) -> None:
        self.assertEqual(ambiguities.parse_token_range(" 12 .. 50 "), (12, 50))

    def test_token_range_rejects_a_descending_range(self) -> None:
        with self.assertRaisesRegex(
            ambiguities.ConfigurationError, "minimum must not exceed"
        ):
            ambiguities.parse_token_range("50..12")

    def test_duration_accepts_friendly_and_composed_units(self) -> None:
        self.assertEqual(ambiguities.parse_duration("1h30m"), 5400)
        self.assertEqual(ambiguities.parse_duration("250ms"), 0.25)
        self.assertEqual(ambiguities.parse_duration(90), 90)

    def test_duration_rejects_trailing_text(self) -> None:
        with self.assertRaisesRegex(ambiguities.ConfigurationError, "invalid duration"):
            ambiguities.parse_duration("30 minutes")


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
        profile = ambiguities.load_profiles(path)["deep"]
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
        overridden = ambiguities.apply_overrides(profile, arguments)
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
            ambiguities.ConfigurationError, "one -> two -> one"
        ):
            ambiguities.load_profiles(path)

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
            ambiguities.ConfigurationError, "unknown settings: surprise"
        ):
            ambiguities.load_profiles(path)


class CommandLineTests(unittest.TestCase):
    def test_search_defaults_to_general(self) -> None:
        arguments = ambiguities.parser().parse_args(["search"])
        self.assertEqual(arguments.profile, "general")

    def test_prove_defaults_to_quick(self) -> None:
        arguments = ambiguities.parser().parse_args(["prove", "3"])
        self.assertEqual(arguments.profile, "quick")

    def test_check_accepts_quoted_or_individual_tokens(self) -> None:
        cli = ambiguities.parser()
        quoted = cli.parse_args(["check", "UIDENT LPAREN RPAREN EOF"])
        separate = cli.parse_args(
            ["check", "UIDENT", "LPAREN", "RPAREN", "EOF"]
        )
        self.assertEqual(" ".join(quoted.tokens), " ".join(separate.tokens))

    def test_engine_arguments_are_stable_and_low_level(self) -> None:
        profile = ambiguities.SearchProfile(
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
            ambiguities.engine_arguments(profile),
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


if __name__ == "__main__":
    unittest.main()
