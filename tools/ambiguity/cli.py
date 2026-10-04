#!/usr/bin/env python3
"""Friendly command-line interface for the ambiguity-search engine."""

from __future__ import annotations

import argparse
from pathlib import Path
import shlex
from typing import Any, Sequence

from tools.ambiguity.profiles import (
    DEFAULT_PROFILES,
    SETTINGS,
    ConfigurationError,
    apply_overrides,
    expand_output_path,
    list_profiles,
    load_profiles,
    profile_summary,
)
from tools.ambiguity.runner import engine_arguments, run_engine

def add_overrides(command: argparse.ArgumentParser) -> None:
    # Every flag - value settings, toggles, and modes alike - is registered from
    # the one registry, so there is no separate cli-only flag list to maintain.
    for setting in SETTINGS:
        if setting.kind == "value":
            options: dict[str, Any] = {
                "metavar": setting.metavar,
                "help": setting.help,
            }
            if setting.arg_type is not None:
                options["type"] = setting.arg_type
            command.add_argument(f"--{setting.key}", **options)
        else:
            command.add_argument(
                f"--{setting.key}", action="store_true", help=setting.help
            )


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        prog="ambiguity",
        description="Search for, check, and prove grammar ambiguity.",
    )
    result.add_argument(
        "--profiles-file",
        type=Path,
        default=DEFAULT_PROFILES,
        help=argparse.SUPPRESS,
    )
    commands = result.add_subparsers(dest="command", required=True)

    search = commands.add_parser(
        "search", help="run a bounded search using a named profile"
    )
    search.add_argument(
        "profile",
        nargs="?",
        default="general",
        help="profile from tools/ambiguity/profiles.toml (default: general)",
    )
    add_overrides(search)

    check = commands.add_parser(
        "check", help="check one exact space-separated token sequence"
    )
    check.add_argument(
        "tokens",
        nargs="+",
        metavar="TOKEN",
        help="terminal names, including EOF when required",
    )

    visible = commands.add_parser(
        "prove-visible", help="prove all accepted parses using exact visible-stack summaries"
    )
    visible.add_argument("--grammar", type=Path, default=Path(__file__).resolve().parents[2] / "lib/cst/parser.mly")
    visible.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[2] / "reports/ambiguity/visible")
    visible.add_argument("--menhir", help="Menhir executable (default: AMBIGUITY_MENHIR or PATH)")
    visible.add_argument("--stock", action="store_true", help="check the stock automaton instead of the shipped GLR preprocessing")
    visible.add_argument("--seconds", type=int, default=300, help="maximum seconds per stage")
    visible.add_argument("--max-nodes", type=int, default=100000, help="fixed-point configuration limit; exhausting it never proves anything")

    commands.add_parser("profiles", help="list available search profiles")
    commands.add_parser(
        "classes",
        help="list the terminal equivalence classes the search collapses",
    )
    return result


def main(argv: Sequence[str] | None = None) -> int:
    cli = parser()
    arguments = cli.parse_args(argv)
    try:
        if arguments.command == "prove-visible":
            from tools.ambiguity.visible.run import run
            if arguments.seconds < 1 or arguments.max_nodes < 1:
                raise ConfigurationError("visible proof limits must be positive")
            return run(arguments.grammar, arguments.output, arguments.menhir,
                       arguments.stock, arguments.seconds, arguments.max_nodes)

        if arguments.command == "check":
            return run_engine(
                ["--check-tokens", " ".join(arguments.tokens)],
                "Exact ambiguity check",
                None,
            )

        if arguments.command == "classes":
            return run_engine(
                ["--dump-terminal-classes"],
                "Terminal equivalence classes",
                None,
            )

        profiles = load_profiles(arguments.profiles_file)
        if arguments.command == "profiles":
            list_profiles(profiles)
            return 0

        if arguments.profile not in profiles:
            available = ", ".join(sorted(profiles))
            raise ConfigurationError(
                f"unknown profile {arguments.profile!r}; available: {available}"
            )
        profile = apply_overrides(profiles[arguments.profile], arguments)
        output_path = (
            None
            if profile.output is None
            else expand_output_path(profile.output, profile.name)
        )
        summary = profile_summary(profile, "Search")
        if output_path is not None:
            summary += f"\nReport: {output_path}"
        engine_args = engine_arguments(profile)
        if arguments.dry_run:
            print(summary)
            print("\nEngine arguments:")
            print("  " + shlex.join(engine_args))
            return 0
        return run_engine(engine_args, summary, output_path)
    except (ConfigurationError, ValueError) as error:
        cli.error(str(error))
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
