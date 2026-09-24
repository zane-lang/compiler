#!/usr/bin/env python3
import argparse
import os
import queue
import shutil
import subprocess
import threading
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import TextIO
import unittest

from tools.ambiguity import cli, profiles, runner

ROOT = Path(__file__).resolve().parents[2]
ENGINE = ROOT / "_build" / "default" / "tools" / "ambiguity" / "ambiguity_search.exe"

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

# The short derivation accepts at A EOF; a longer accepted derivation needs
# that prefix to remain expandable until the requested four-token boundary.
MIN_TOKENS_GRAMMAR = """\
%token A "a"
%token X "x"
%token EOF "<eof>"
%start <unit> main
%%
main:
  | e EOF { () }
  | e EOF X EOF { () }
e:
  | A { () }
  | A { () }
"""

# A deliberately branchy expression grammar for the progress-pipe check. The
# tiny grammar above settles its proof before the engine's 128-pair progress
# cadence is reached, so it cannot exercise progress output reliably.
PROGRESS_GRAMMAR = """\
%token A "a"
%token B "b"
%token PLUS "+"
%token TIMES "*"
%token MINUS "-"
%token SLASH "/"
%token EOF "<eof>"
%start <unit> main
%%
main: e EOF { () }
e:
  | A { () }
  | B { () }
  | e PLUS e { () }
  | e TIMES e { () }
  | e MINUS e { () }
  | e SLASH e { () }
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


class CommandLineTests(unittest.TestCase):
    def test_search_defaults_to_general(self) -> None:
        arguments = cli.parser().parse_args(["search"])
        self.assertEqual(arguments.profile, "general")

    def test_prove_defaults_to_quick(self) -> None:
        arguments = cli.parser().parse_args(["prove", "3"])
        self.assertEqual(arguments.profile, "quick")

    def test_check_accepts_quoted_or_individual_tokens(self) -> None:
        command = cli.parser()
        quoted = command.parse_args(["check", "UIDENT LPAREN RPAREN EOF"])
        separate = command.parse_args(
            ["check", "UIDENT", "LPAREN", "RPAREN", "EOF"]
        )
        self.assertEqual(" ".join(quoted.tokens), " ".join(separate.tokens))

    def test_engine_arguments_are_stable_and_low_level(self) -> None:
        profile = profiles.SearchProfile(
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
            runner.engine_arguments(profile),
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


class SurveyFlagTests(unittest.TestCase):
    """The survey reaches the engine only when asked for."""

    def profile(self) -> profiles.SearchProfile:
        return profiles.SearchProfile(
            name="quick",
            description="",
            min_tokens=0,
            max_tokens=16,
            timeout_seconds=900,
            witnesses=50,
            prefix_tokens=(),
            nodes_per_depth=None,
        )

    def test_a_survey_is_absent_unless_requested(self) -> None:
        arguments = runner.engine_arguments(self.profile(), 3)
        self.assertNotIn("--prove-survey", arguments)

    def test_a_requested_survey_reaches_the_engine(self) -> None:
        arguments = runner.engine_arguments(self.profile(), 3, 5)
        self.assertIn("--prove-survey", arguments)
        self.assertEqual(
            arguments[arguments.index("--prove-survey") + 1], "5"
        )

    def test_requested_CEGAR_reaches_the_engine(self) -> None:
        arguments = runner.engine_arguments(self.profile(), 3, cegar=2)
        self.assertEqual(arguments[arguments.index("--prove-cegar") + 1], "2")

    def test_refinement_is_absent_unless_requested(self) -> None:
        arguments = runner.engine_arguments(self.profile(), 3)
        self.assertNotIn("--prove-refine", arguments)
        self.assertNotIn("--prove-refine-rounds", arguments)

    def test_requested_refinement_reaches_the_engine(self) -> None:
        arguments = runner.engine_arguments(self.profile(), 3, refine=9)
        self.assertIn("--prove-refine", arguments)
        self.assertEqual(arguments[arguments.index("--prove-refine") + 1], "9")

    def test_a_round_limit_only_travels_with_refinement(self) -> None:
        # The engine has its own default, so passing a round limit without
        # refinement would set a bound on something that is not running.
        arguments = runner.engine_arguments(
            self.profile(), 3, refine=0, refine_rounds=4
        )
        self.assertNotIn("--prove-refine-rounds", arguments)
        arguments = runner.engine_arguments(
            self.profile(), 3, refine=9, refine_rounds=4
        )
        self.assertEqual(
            arguments[arguments.index("--prove-refine-rounds") + 1], "4"
        )

    def test_retirement_only_travels_with_refinement(self) -> None:
        # Retiring names what refinement failed to close, so on its own it has
        # nothing to act on and the engine would never see the option.
        arguments = runner.engine_arguments(self.profile(), 3, refine=0, retire=2)
        self.assertNotIn("--prove-retire", arguments)
        arguments = runner.engine_arguments(self.profile(), 3, refine=9, retire=2)
        self.assertEqual(arguments[arguments.index("--prove-retire") + 1], "2")

    def test_a_trace_only_travels_when_asked(self) -> None:
        self.assertNotIn("--prove-trace", runner.engine_arguments(self.profile(), 3))
        self.assertIn(
            "--prove-trace",
            runner.engine_arguments(self.profile(), 3, trace=True),
        )

    def test_the_wrapper_rejects_its_own_invalid_refinements(self) -> None:
        # The wrapper repeats two checks the engine also makes, so that the
        # message names the option the caller typed rather than the engine's
        # spelling of it. Without a test the duplication can rot away silently:
        # the run still fails, just with the wrong option name in the error.
        for name, argv in (
            ("below the proof level", ["prove", "4", "--refine", "2"]),
            ("with a survey", ["prove", "1", "--refine", "4", "--survey", "1"]),
            ("rounds without refinement", ["prove", "1", "--refine-rounds", "4"]),
            ("trace with a survey", ["prove", "1", "--trace", "--survey", "1"]),
            ("retire without refinement", ["prove", "1", "--retire", "2"]),
            ("negative CEGAR rounds", ["prove", "1", "--cegar", "-1"]),
            ("CEGAR with a survey", ["prove", "1", "--cegar", "1", "--survey", "1"]),
        ):
            with self.subTest(combination=name):
                with self.assertRaises(SystemExit):
                    cli.main([*argv, "--dry-run"])

    def test_the_wrapper_accepts_a_valid_refinement(self) -> None:
        # The guard against the test above passing because every prove
        # invocation is rejected.
        self.assertEqual(
            cli.main(
                ["prove", "1", "--refine", "4", "--refine-rounds", "2", "--dry-run"]
            ),
            0,
        )

    def test_the_wrapper_accepts_CEGAR(self) -> None:
        self.assertEqual(cli.main(["prove", "1", "--cegar", "2", "--dry-run"]), 0)


class TerminalClassEngineTests(unittest.TestCase):
    """End-to-end checks that the search collapses interchangeable terminals
    without losing an ambiguity reachable only through a non-representative
    member. Skipped when the engine binary or menhir is unavailable, so the
    otherwise pure-Python suite still runs without the OCaml toolchain."""

    def setUp(self) -> None:
        self.environment = engine_environment()
        if self.environment is None:
            self.skipTest(
                "requires a built _build/default/tools/ambiguity/ambiguity_search.exe and menhir"
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
        self.assertEqual(result.returncode, 0)

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
        # TINY_GRAMMAR is ambiguous, so proof mode settles on the ambiguous
        # verdict and reports it in its status.
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertTrue(
            "complete ambiguity" in result.stdout
            or "AMBIGUOUS: the recognizer found two derivations" in result.stdout,
            result.stdout,
        )
        # The witness must be spelled with the class representative A, never the
        # non-representative B, confirming concretization stays on representatives.
        witnesses = [
            line for line in result.stdout.splitlines() if "Tokens (" in line
        ]
        if witnesses:
            tokens = witnesses[0].split(":", 1)[1].split()
            self.assertIn("A", tokens)
            self.assertNotIn("B", tokens)
        else:
            self.assertIn(
                "AMBIGUOUS: the recognizer found two derivations of A PLUS A PLUS A EOF",
                result.stdout,
            )


class MinTokenEngineTests(unittest.TestCase):
    """Accepted prefixes below --min-tokens must stay expandable and bounded."""

    def setUp(self) -> None:
        self.environment = engine_environment()
        if self.environment is None:
            self.skipTest(
                "requires a built _build/default/tools/ambiguity/ambiguity_search.exe and menhir"
            )
        directory = TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.grammar = Path(directory.name) / "min_tokens.mly"
        self.grammar.write_text(MIN_TOKENS_GRAMMAR, encoding="utf-8")

    def test_expands_an_accepted_prefix_to_the_requested_boundary(self) -> None:
        for jobs in (1, 2):
            with self.subTest(jobs=jobs):
                result = subprocess.run(
                    [
                        str(ENGINE),
                        "--min-tokens", "4",
                        "--max-tokens", "4",
                        "--timeout", "30",
                        "--max-witnesses", "1",
                        str(self.grammar),
                    ],
                    env={**self.environment, "AMBIGUITY_JOBS": str(jobs)},
                    text=True,
                    capture_output=True,
                    timeout=120,
                )
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertIn("Found 1 complete ambiguity family.", result.stdout)
                self.assertIn("Tokens (4): A EOF X EOF", result.stdout)


class PartitionBudgetEngineTests(unittest.TestCase):
    """The parallel prepass must stay within budget and report truncation."""

    def setUp(self) -> None:
        self.environment = engine_environment()
        if self.environment is None:
            self.skipTest(
                "requires a built _build/default/tools/ambiguity/ambiguity_search.exe and menhir"
            )
        directory = TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.grammar = Path(directory.name) / "branching_min_tokens.mly"
        count = 300
        tokens = "\n".join(
            f'%token X{index} "x{index}"\n%token Y{index} "y{index}"'
            for index in range(count)
        )
        continuations = "\n".join(
            f"  | e EOF X{index} Y{index} Z EOF {{ () }}"
            for index in range(count)
        )
        self.grammar.write_text(
            f"""%token A "a"
%token Z "z"
%token EOF "<eof>"
{tokens}
%start <unit> main
%%
main:
  | e EOF {{ () }}
{continuations}
e:
  | A {{ () }}
  | A {{ () }}
""",
            encoding="utf-8",
        )

    def test_parallel_prepass_reports_frontier_budget_truncation(self) -> None:
        result = subprocess.run(
            [
                str(ENGINE),
                "--min-tokens", "6",
                "--max-tokens", "6",
                "--timeout", "30",
                "--max-witnesses", "1",
                str(self.grammar),
            ],
            env={
                **self.environment,
                "AMBIGUITY_JOBS": "4",
                "AMBIGUITY_MEMORY_MB": "512",
                "AMBIGUITY_MAX_FRONTIER_RATIO": "0.001",
            },
            text=True,
            capture_output=True,
            timeout=120,
        )
        self.assertIn(
            "the frontier budget stopped initial partitioning", result.stdout
        )
        self.assertNotIn("the search space within the token bound was exhausted", result.stdout)


class StreamingOutputTests(unittest.TestCase):
    """The engine's output has to arrive while a run is happening, not when it
    ends.

    Every wrapper reads it through a pipe -- `ambiguity` streams it to the
    terminal and into the saved report, the sweep passes each level's through --
    and on a pipe OCaml block-buffers stdout. A whole proof run's output used to
    sit in that buffer until the process exited, so a report file stayed empty
    for the run it was documenting, and a search that ran for an hour said
    nothing while it did. Skipped when the engine binary or menhir is
    unavailable, like the other end-to-end checks here."""

    def setUp(self) -> None:
        self.environment = engine_environment()
        if self.environment is None:
            self.skipTest(
                "requires a built _build/default/tools/ambiguity/ambiguity_search.exe and menhir"
            )
        directory = TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.grammar = Path(directory.name) / "tiny.mly"
        self.grammar.write_text(TINY_GRAMMAR, encoding="utf-8")

    def engine(
        self, *arguments: str, **overrides: str
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(ENGINE), *arguments, str(self.grammar)],
            env={**self.environment, **overrides},
            text=True,
            capture_output=True,
            timeout=120,
        )

    @staticmethod
    def first_line(handle: TextIO, seconds: float) -> str | None:
        """The first line, or None if none arrives within ``seconds``.

        Read on a thread rather than with a plain `readline`, which would block
        for as long as the run lasts -- exactly the state this test has to be
        able to observe from the outside.
        """
        lines: queue.Queue[str] = queue.Queue()
        reader = threading.Thread(
            target=lambda: lines.put(handle.readline()), daemon=True
        )
        reader.start()
        try:
            return lines.get(timeout=seconds)
        except queue.Empty:
            return None

    def test_the_first_line_arrives_before_the_run_ends(self) -> None:
        # Zane's own grammar with a long deadline: the abstract phase is still
        # walking when the first line is read, which is what makes the read
        # evidence of flushing rather than of a run that happened to be over.
        process = subprocess.Popen(
            [
                str(ENGINE),
                "--prove", "2",
                "--prove-survey", "1",
                "--max-tokens", "8",
                "--timeout", "60",
                "--max-witnesses", "2",
                str(ROOT / "lib" / "cst" / "parser.mly"),
            ],
            env={**self.environment, "AMBIGUITY_MEMORY_MB": "512"},
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )

        def stop() -> None:
            process.kill()
            process.wait()
            if process.stdout is not None:
                process.stdout.close()

        self.addCleanup(stop)
        assert process.stdout is not None
        line = self.first_line(process.stdout, 60)
        self.assertIsNotNone(line, "no output arrived while the engine ran")
        self.assertIn("Search constraints", line or "")
        self.assertIsNone(
            process.poll(), "the engine exited before the line could prove anything"
        )

    def test_progress_reaches_a_pipe(self) -> None:
        # Use enough unresolved expression branches to cross the engine's
        # progress cadence. The tiny grammar settles before 128 pairs, so it
        # cannot exercise progress output reliably.
        self.grammar.write_text(PROGRESS_GRAMMAR, encoding="utf-8")
        result = self.engine(
            "--prove", "2",
            "--prove-survey", "1",
            "--max-tokens", "24",
            "--timeout", "5",
            "--max-witnesses", "5",
            AMBIGUITY_PROGRESS_SECONDS="0.05",
        )
        # Survey mode keeps the run in the abstract phase, so this cannot be
        # satisfied by the concrete-search force emission after a candidate.
        self.assertIn("Survey at level", result.stdout)
        self.assertTrue(
            any(line.startswith("●") for line in result.stderr.splitlines()),
            result.stderr,
        )

    def test_progress_can_be_switched_off(self) -> None:
        result = self.engine(
            "--prove", "2",
            "--max-tokens", "24",
            "--timeout", "5",
            "--max-witnesses", "5",
            AMBIGUITY_PROGRESS_SECONDS="0",
        )
        self.assertNotIn("●", result.stderr)

    def cadence(self, value: str) -> subprocess.CompletedProcess[str]:
        return self.engine(
            "--prove", "2",
            "--max-tokens", "8",
            "--timeout", "5",
            "--max-witnesses", "5",
            AMBIGUITY_PROGRESS_SECONDS=value,
        )

    def test_a_malformed_cadence_is_an_ordinary_error(self) -> None:
        result = self.cadence("often")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn(
            "AMBIGUITY_PROGRESS_SECONDS must be a finite number", result.stderr
        )
        # Reported by the toplevel handler rather than as an uncaught exception.
        # That handler clears the progress line first, and reading the setting
        # a second time there is what used to turn the error into a crash.
        self.assertNotIn("Fatal error", result.stderr)

    def test_a_non_finite_cadence_is_refused_rather_than_obeyed(self) -> None:
        # These parse as floats, so they used to be taken for a setting and
        # then show no progress at all -- silently, and in two different ways.
        # Every comparison against nan is false, so it read as switched off;
        # nothing is ever as old as infinity, so a run reported progress as
        # enabled and never printed a line. Neither is a cadence anyone asked
        # for, so both are refused like any other bad setting.
        for value in ("nan", "infinity", "-infinity"):
            with self.subTest(cadence=value):
                result = self.cadence(value)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(
                    "AMBIGUITY_PROGRESS_SECONDS must be a finite number",
                    result.stderr,
                )
                self.assertNotIn("Fatal error", result.stderr)


if __name__ == "__main__":
    unittest.main()
