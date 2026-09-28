#!/usr/bin/env python3
"""Tests of tools/ambiguity/profiles.py: value parsing, profiles and output
paths."""

import argparse
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from tools.ambiguity import cli, profiles


class ValueParsingTests(unittest.TestCase):
    def test_token_range_accepts_whitespace(self) -> None:
        self.assertEqual(profiles.parse_token_range(" 12 .. 50 "), (12, 50))

    def test_token_range_rejects_a_descending_range(self) -> None:
        with self.assertRaisesRegex(
            profiles.ConfigurationError, "minimum must not exceed"
        ):
            profiles.parse_token_range("50..12")

    def test_duration_accepts_friendly_and_composed_units(self) -> None:
        self.assertEqual(profiles.parse_duration("1h30m"), 5400)
        self.assertEqual(profiles.parse_duration("250ms"), 0.25)
        self.assertEqual(profiles.parse_duration(90), 90)

    def test_duration_rejects_trailing_text(self) -> None:
        with self.assertRaisesRegex(profiles.ConfigurationError, "invalid duration"):
            profiles.parse_duration("30 minutes")


class ProfileTests(unittest.TestCase):
    def write_profiles(self, contents: str) -> Path:
        directory = TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = Path(directory.name) / "searches.toml"
        path.write_text(contents, encoding="utf-8")
        return path

    def override_namespace(self, **overrides: object) -> argparse.Namespace:
        # Mirror argparse defaults: every override dest is None (store_true
        # flags are False) unless the test sets it.
        namespace = {setting.dest: None for setting in profiles.SETTINGS}
        namespace["breadth_first"] = False
        namespace.update(overrides)
        return argparse.Namespace(**namespace)

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
prefix-tokens = ["UIDENT", "LCURLY"]
nodes-per-depth = 4
output = "reports/{profile}-{date}.txt"
"""
        )
        profile = profiles.load_profiles(path)["deep"]
        self.assertEqual(profile.description, "Broad search.")
        self.assertEqual((profile.min_tokens, profile.max_tokens), (12, 50))
        self.assertEqual(profile.timeout_seconds, 120)
        self.assertEqual(profile.prefix_tokens, ("UIDENT", "LCURLY"))
        self.assertEqual(profile.nodes_per_depth, 4)
        self.assertEqual(profile.output, Path("reports/{profile}-{date}.txt"))

        arguments = self.override_namespace(
            tokens="10..30",
            timeout="1h",
            witnesses=25,
            prefix_tokens="UIDENT LIDENT",
            breadth_first=True,
        )
        overridden = profiles.apply_overrides(profile, arguments)
        self.assertEqual((overridden.min_tokens, overridden.max_tokens), (10, 30))
        self.assertEqual(overridden.timeout_seconds, 3600)
        self.assertEqual(overridden.witnesses, 25)
        self.assertEqual(overridden.prefix_tokens, ("UIDENT", "LIDENT"))
        self.assertIsNone(overridden.nodes_per_depth)
        # The profile's output survives when no --output override is given.
        self.assertEqual(overridden.output, Path("reports/{profile}-{date}.txt"))

    def test_output_key_and_override(self) -> None:
        path = self.write_profiles(
            """
[profiles.quick]
tokens = "0..10"
timeout = "1m"
witnesses = 5
output = "reports/{profile}.txt"
"""
        )
        profile = profiles.load_profiles(path)["quick"]
        self.assertEqual(profile.output, Path("reports/{profile}.txt"))
        overridden = profiles.apply_overrides(
            profile, self.override_namespace(output=Path("elsewhere.txt"))
        )
        self.assertEqual(overridden.output, Path("elsewhere.txt"))

    def test_output_must_be_a_string_path(self) -> None:
        path = self.write_profiles(
            """
[profiles.quick]
tokens = "0..10"
timeout = "1m"
witnesses = 5
output = 5
"""
        )
        with self.assertRaisesRegex(
            profiles.ConfigurationError, "output must be a string path"
        ):
            profiles.load_profiles(path)

    def test_prefix_must_leave_room_for_eof(self) -> None:
        # A prefix that fills the entire max_tokens budget leaves no slot for the
        # required EOF token, so it can never complete a witness.
        path = self.write_profiles(
            """
[profiles.quick]
tokens = "0..3"
timeout = "1m"
witnesses = 5
prefix-tokens = ["UIDENT", "LPAREN", "RPAREN"]
"""
        )
        with self.assertRaisesRegex(
            profiles.ConfigurationError, "no room for the EOF token"
        ):
            profiles.load_profiles(path)

    def test_single_registry_drives_flags_and_keys(self) -> None:
        # The whole point of the registry: one list enumerates every flag, and
        # each entry marks whether it is also a TOML key. Every setting registers
        # a flag; only profile_key settings are valid TOML keys.
        search = cli.parser().parse_args(["search"])
        for setting in profiles.SETTINGS:
            self.assertTrue(hasattr(search, setting.dest))
            self.assertEqual(
                setting.profile_key, setting.key in profiles.PROFILE_KEYS
            )
        # dry-run is a mode, so it is the one flag that is not a TOML key.
        self.assertNotIn("dry-run", profiles.PROFILE_KEYS)
        self.assertIn("breadth-first", profiles.PROFILE_KEYS)

    def test_breadth_first_profile_key(self) -> None:
        path = self.write_profiles(
            """
[profiles.quick]
tokens = "0..10"
timeout = "1m"
witnesses = 5
breadth-first = true
"""
        )
        self.assertIsNone(profiles.load_profiles(path)["quick"].nodes_per_depth)

    def test_breadth_first_must_be_true(self) -> None:
        path = self.write_profiles(
            """
[profiles.quick]
tokens = "0..10"
timeout = "1m"
witnesses = 5
breadth-first = false
"""
        )
        with self.assertRaisesRegex(
            profiles.ConfigurationError, "breadth-first must be true"
        ):
            profiles.load_profiles(path)

    def test_scheduling_keys_are_mutually_exclusive(self) -> None:
        path = self.write_profiles(
            """
[profiles.quick]
tokens = "0..10"
timeout = "1m"
witnesses = 5
nodes-per-depth = 4
breadth-first = true
"""
        )
        with self.assertRaisesRegex(
            profiles.ConfigurationError, "at most one of nodes-per-depth"
        ):
            profiles.load_profiles(path)

    def test_child_breadth_first_overrides_inherited_depth(self) -> None:
        path = self.write_profiles(
            """
[profiles.base]
tokens = "0..10"
timeout = "1m"
witnesses = 5
nodes-per-depth = 8

[profiles.child]
extends = "base"
breadth-first = true
"""
        )
        self.assertIsNone(profiles.load_profiles(path)["child"].nodes_per_depth)

    def test_child_depth_overrides_inherited_breadth_first(self) -> None:
        path = self.write_profiles(
            """
[profiles.base]
tokens = "0..10"
timeout = "1m"
witnesses = 5
breadth-first = true

[profiles.child]
extends = "base"
nodes-per-depth = 8
"""
        )
        self.assertEqual(profiles.load_profiles(path)["child"].nodes_per_depth, 8)

    def test_dry_run_is_not_a_profile_key(self) -> None:
        path = self.write_profiles(
            """
[profiles.quick]
tokens = "0..10"
timeout = "1m"
witnesses = 5
dry-run = true
"""
        )
        with self.assertRaisesRegex(
            profiles.ConfigurationError, "unknown settings: dry-run"
        ):
            profiles.load_profiles(path)

    def test_snake_case_key_is_rejected(self) -> None:
        path = self.write_profiles(
            """
[profiles.quick]
tokens = "0..10"
timeout = "1m"
witnesses = 5
prefix_tokens = ["UIDENT"]
"""
        )
        with self.assertRaisesRegex(
            profiles.ConfigurationError, "unknown settings: prefix_tokens"
        ):
            profiles.load_profiles(path)

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
            profiles.ConfigurationError, "one -> two -> one"
        ):
            profiles.load_profiles(path)

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
            profiles.ConfigurationError, "unknown settings: surprise"
        ):
            profiles.load_profiles(path)


class OutputPatternTests(unittest.TestCase):
    def test_profile_and_date_placeholders_expand(self) -> None:
        path = profiles.expand_output_path(
            Path("reports/{profile}-{date}.txt"), "general"
        )
        self.assertRegex(str(path), r"^reports/general-\d{4}-\d{2}-\d{2}\.txt$")

    def test_timestamp_placeholders_expand(self) -> None:
        path = profiles.expand_output_path(
            Path("{profile}_{datetime}--{time}"), "deep"
        )
        self.assertRegex(
            str(path),
            r"^deep_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}--\d{2}-\d{2}-\d{2}$",
        )

    def test_plain_path_is_unchanged(self) -> None:
        self.assertEqual(
            profiles.expand_output_path(Path("report.txt"), "general"),
            Path("report.txt"),
        )

    def test_unknown_placeholder_is_reported(self) -> None:
        with self.assertRaisesRegex(
            profiles.ConfigurationError, "unknown placeholder"
        ):
            profiles.expand_output_path(Path("reports/{oops}.txt"), "general")

    def test_unbalanced_brace_is_reported(self) -> None:
        with self.assertRaisesRegex(
            profiles.ConfigurationError, "invalid --output pattern"
        ):
            profiles.expand_output_path(Path("reports/{profile.txt"), "general")

    def test_literal_braces_are_preserved(self) -> None:
        self.assertEqual(
            profiles.expand_output_path(Path("reports/{{profile}}.txt"), "general"),
            Path("reports/{profile}.txt"),
        )

    def test_indexed_placeholder_is_rejected(self) -> None:
        # str.format_map would silently expand this to the first character.
        with self.assertRaisesRegex(
            profiles.ConfigurationError, "unknown placeholder"
        ):
            profiles.expand_output_path(Path("{profile[0]}.txt"), "general")

    def test_attribute_placeholder_is_rejected(self) -> None:
        # str.format_map would raise an uncaught AttributeError here.
        with self.assertRaisesRegex(
            profiles.ConfigurationError, "unknown placeholder"
        ):
            profiles.expand_output_path(Path("{profile.foo}.txt"), "general")

    def test_format_spec_is_rejected(self) -> None:
        with self.assertRaisesRegex(
            profiles.ConfigurationError, "no format spec or conversion"
        ):
            profiles.expand_output_path(Path("{profile:>10}.txt"), "general")


if __name__ == "__main__":
    unittest.main()
