#!/usr/bin/env python3
"""Friendly command-line interface for the ambiguity-search engine."""

from __future__ import annotations

import argparse
from pathlib import Path
import shlex
import sys
from typing import Any, Sequence

# Run as a script -- `dev/bin/ambiguity` execs this file by path -- sys.path
# starts at this directory rather than the repository root, so the modules
# beside it are not reachable by package path until the root is on it.
# Imported as `tools.ambiguity.cli` the root is already there and this is a
# no-op. `precision_sweep.py` bootstraps itself the same way.
ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.ambiguity.profiles import (  # noqa: E402
    DEFAULT_PROFILES,
    SETTINGS,
    ConfigurationError,
    apply_overrides,
    expand_output_path,
    list_profiles,
    load_profiles,
    profile_summary,
)
from tools.ambiguity.runner import engine_arguments, run_engine  # noqa: E402

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
        help="profile from ambiguity-searches.toml (default: general)",
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

    prove = commands.add_parser(
        "prove", help="attempt an unbounded top-K proof, then concretize if needed"
    )
    prove.add_argument("level", type=int, metavar="LEVEL")
    prove.add_argument(
        "profile",
        nargs="?",
        default="quick",
        help="profile for bounded concretization (default: quick)",
    )
    prove.add_argument(
        "--survey",
        type=int,
        default=0,
        metavar="N",
        help=(
            "do not stop at the first divergence: count every distinct site "
            "the abstraction cannot separate, showing up to N examples"
        ),
    )
    prove.add_argument(
        "--refine",
        type=int,
        default=0,
        metavar="K",
        help=(
            "treat a candidate as a reason to sharpen the abstraction rather "
            "than as an answer: deepen the retained stack behind it, up to K "
            "states, and try again"
        ),
    )
    prove.add_argument(
        "--trace",
        action="store_true",
        help=(
            "follow the reported candidate from its divergence site down to "
            "acceptance, naming every step where a side had to guess a goto"
        ),
    )
    prove.add_argument(
        "--refine-rounds",
        type=int,
        default=0,
        metavar="N",
        help="give up refining after N rounds (default: the engine's own)",
    )
    prove.add_argument(
        "--retire",
        type=int,
        default=0,
        metavar="N",
        help=(
            "stop pursuing a divergence site once N rounds of deepening have "
            "left the candidate at the same site, and carry on with the rest "
            "of the grammar; a run that retires anything never reports a proof"
        ),
    )
    add_overrides(prove)

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
        if arguments.command == "prove" and arguments.level < 1:
            raise ConfigurationError("proof level must be at least 1")
        proof_level = arguments.level if arguments.command == "prove" else None
        action = (
            f"Proof level {proof_level}, concretization"
            if proof_level is not None
            else "Search"
        )
        output_path = (
            None
            if profile.output is None
            else expand_output_path(profile.output, profile.name)
        )
        summary = profile_summary(profile, action)
        if output_path is not None:
            summary += f"\nReport: {output_path}"
        survey = getattr(arguments, "survey", 0)
        if survey < 0:
            raise ConfigurationError("--survey must be non-negative")
        refine = getattr(arguments, "refine", 0)
        refine_rounds = getattr(arguments, "refine_rounds", 0)
        if refine < 0:
            raise ConfigurationError("--refine must be non-negative")
        if refine_rounds < 0:
            raise ConfigurationError("--refine-rounds must be non-negative")
        # Without --refine there is no loop for a round limit to bound, and the
        # engine never sees the option, so accepting it would run exactly as if
        # it had not been typed.
        if refine_rounds > 0 and refine == 0:
            raise ConfigurationError("--refine-rounds requires --refine")
        # Caught here rather than left to the engine so the message names the
        # option the caller actually typed.
        if refine > 0 and proof_level is not None and refine < proof_level:
            raise ConfigurationError("--refine must be at least the proof level")
        if refine > 0 and survey > 0:
            raise ConfigurationError("--refine cannot be combined with --survey")
        retire = getattr(arguments, "retire", 0)
        if retire < 0:
            raise ConfigurationError("--retire must be non-negative")
        # Retiring names what refinement failed to close, so it has nothing to
        # act on without refinement, and the engine would never see the option.
        if retire > 0 and refine == 0:
            raise ConfigurationError("--retire requires --refine")
        trace = getattr(arguments, "trace", False)
        # A survey reports every site rather than one candidate, so there is no
        # single path for a trace to follow.
        if trace and survey > 0:
            raise ConfigurationError("--trace cannot be combined with --survey")
        engine_args = engine_arguments(
            profile, proof_level, survey, refine, refine_rounds, retire, trace
        )
        if arguments.dry_run:
            print(summary)
            print("\nEngine arguments:")
            print("  " + shlex.join(engine_args))
            return 0
        return run_engine(engine_args, summary, output_path)
    except ConfigurationError as error:
        cli.error(str(error))
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
