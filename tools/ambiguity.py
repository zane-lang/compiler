#!/usr/bin/env python3
"""Friendly command-line interface for the ambiguity-search engine."""

from __future__ import annotations

import argparse
from dataclasses import dataclass, replace
import datetime
from pathlib import Path
import re
import shlex
import string
import subprocess
import sys
import tomllib
from typing import Any, Sequence, TextIO


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_PROFILES = ROOT / "ambiguity-searches.toml"
ENGINE_RUNNER = ROOT / "dev" / "bin" / "ambiguity"

PROFILE_KEYS = {
    "description",
    "extends",
    "tokens",
    "timeout",
    "witnesses",
    "prefix_tokens",
    "nodes_per_depth",
}
DURATION_PART = re.compile(r"(\d+(?:\.\d+)?)(ms|s|m|h)")
DURATION_FACTORS = {"ms": 0.001, "s": 1.0, "m": 60.0, "h": 3600.0}


class ConfigurationError(ValueError):
    pass


@dataclass(frozen=True)
class SearchProfile:
    name: str
    description: str
    min_tokens: int
    max_tokens: int
    timeout_seconds: float
    witnesses: int
    prefix_tokens: tuple[str, ...] = ()
    nodes_per_depth: int | None = None


def parse_token_range(value: str) -> tuple[int, int]:
    match = re.fullmatch(r"\s*(\d+)\s*\.\.\s*(\d+)\s*", value)
    if match is None:
        raise ConfigurationError(
            f"invalid token range {value!r}; expected MIN..MAX"
        )
    minimum, maximum = map(int, match.groups())
    if minimum > maximum:
        raise ConfigurationError("token range minimum must not exceed its maximum")
    return minimum, maximum


def parse_duration(value: str | int | float) -> float:
    if isinstance(value, bool):
        raise ConfigurationError("duration must be a number or a value such as 30m")
    if isinstance(value, (int, float)):
        seconds = float(value)
    else:
        text = value.strip().lower()
        if re.fullmatch(r"\d+(?:\.\d+)?", text):
            seconds = float(text)
        else:
            seconds = 0.0
            position = 0
            for match in DURATION_PART.finditer(text):
                if match.start() != position:
                    break
                seconds += float(match.group(1)) * DURATION_FACTORS[match.group(2)]
                position = match.end()
            if position != len(text) or position == 0:
                raise ConfigurationError(
                    f"invalid duration {value!r}; use values such as 90s, 30m, or 1h"
                )
    if seconds < 0:
        raise ConfigurationError("duration must be non-negative")
    return seconds


def format_duration(seconds: float) -> str:
    if seconds == 0:
        return "0s"
    if seconds % 3600 == 0:
        return f"{seconds / 3600:g}h"
    if seconds % 60 == 0:
        return f"{seconds / 60:g}m"
    return f"{seconds:g}s"


def expand_output_path(pattern: Path, profile_name: str) -> Path:
    """Substitute report-naming placeholders in an --output pattern.

    Placeholders use brace syntax: ``{name}``, with ``{{`` and ``}}`` for
    literal braces. The supported names are ``profile`` and three timestamp
    forms whose date and time layout matches the existing ``reports/``
    filenames (e.g. ``2026-07-23_21-38-17``)."""
    now = datetime.datetime.now()
    fields = {
        "profile": profile_name,
        "date": now.strftime("%Y-%m-%d"),
        "time": now.strftime("%H-%M-%S"),
        "datetime": now.strftime("%Y-%m-%d_%H-%M-%S"),
    }
    available = ", ".join("{" + name + "}" for name in fields)
    text = str(pattern)
    # Expand only bare `{name}` placeholders. Parsing the pattern ourselves —
    # rather than str.format_map — keeps indexed or attribute forms such as
    # {profile[0]} or {profile.foo} out: format_map would silently expand the
    # former to a wrong path and raise an uncaught AttributeError on the latter.
    try:
        parsed = list(string.Formatter().parse(text))
    except ValueError as error:
        raise ConfigurationError(
            f"invalid --output pattern {text!r}: {error}; "
            "write {{ and }} for literal braces"
        ) from error
    result: list[str] = []
    for literal, field, spec, conversion in parsed:
        result.append(literal)
        if field is None:
            continue
        if field not in fields:
            raise ConfigurationError(
                f"unknown placeholder {{{field}}} in --output pattern "
                f"{text!r}; available placeholders are {available}"
            )
        if spec or conversion:
            raise ConfigurationError(
                f"--output placeholder {{{field}}} takes no format spec or "
                f"conversion in pattern {text!r}"
            )
        result.append(fields[field])
    return Path("".join(result))


def _profile_tables(path: Path) -> dict[str, dict[str, Any]]:
    try:
        with path.open("rb") as source:
            document = tomllib.load(source)
    except OSError as error:
        raise ConfigurationError(f"cannot read profiles from {path}: {error}") from error
    except tomllib.TOMLDecodeError as error:
        raise ConfigurationError(f"invalid TOML in {path}: {error}") from error
    tables = document.get("profiles")
    if not isinstance(tables, dict) or not tables:
        raise ConfigurationError(f"{path} must contain at least one [profiles.NAME]")
    result: dict[str, dict[str, Any]] = {}
    for name, table in tables.items():
        if not isinstance(table, dict):
            raise ConfigurationError(f"profile {name!r} must be a TOML table")
        unknown = set(table) - PROFILE_KEYS
        if unknown:
            keys = ", ".join(sorted(unknown))
            raise ConfigurationError(f"profile {name!r} has unknown settings: {keys}")
        result[name] = table
    return result


def load_profiles(path: Path = DEFAULT_PROFILES) -> dict[str, SearchProfile]:
    tables = _profile_tables(path)
    resolved: dict[str, dict[str, Any]] = {}
    resolving: list[str] = []

    def resolve(name: str) -> dict[str, Any]:
        if name in resolved:
            return resolved[name]
        if name not in tables:
            raise ConfigurationError(f"unknown inherited profile {name!r}")
        if name in resolving:
            cycle = " -> ".join([*resolving, name])
            raise ConfigurationError(f"profile inheritance cycle: {cycle}")
        resolving.append(name)
        table = tables[name]
        parent = table.get("extends")
        if parent is not None and not isinstance(parent, str):
            raise ConfigurationError(f"profile {name!r}: extends must be a string")
        merged = dict(resolve(parent)) if parent else {}
        merged.update({key: value for key, value in table.items() if key != "extends"})
        resolving.pop()
        resolved[name] = merged
        return merged

    profiles: dict[str, SearchProfile] = {}
    for name in tables:
        settings = resolve(name)
        missing = {"tokens", "timeout", "witnesses"} - set(settings)
        if missing:
            keys = ", ".join(sorted(missing))
            raise ConfigurationError(f"profile {name!r} is missing: {keys}")
        token_value = settings["tokens"]
        if not isinstance(token_value, str):
            raise ConfigurationError(f"profile {name!r}: tokens must be MIN..MAX")
        minimum, maximum = parse_token_range(token_value)
        witnesses = settings["witnesses"]
        if isinstance(witnesses, bool) or not isinstance(witnesses, int) or witnesses < 1:
            raise ConfigurationError(
                f"profile {name!r}: witnesses must be an integer of at least 1"
            )
        prefix = settings.get("prefix_tokens", [])
        if not isinstance(prefix, list) or not all(
            isinstance(token, str) and token for token in prefix
        ):
            raise ConfigurationError(
                f"profile {name!r}: prefix_tokens must be an array of token names"
            )
        nodes = settings.get("nodes_per_depth")
        if nodes is not None and (
            isinstance(nodes, bool) or not isinstance(nodes, int) or nodes < 1
        ):
            raise ConfigurationError(
                f"profile {name!r}: nodes_per_depth must be an integer of at least 1"
            )
        if len(prefix) > maximum:
            raise ConfigurationError(
                f"profile {name!r}: prefix is longer than the maximum token count"
            )
        description = settings.get("description", "")
        if not isinstance(description, str):
            raise ConfigurationError(f"profile {name!r}: description must be a string")
        profiles[name] = SearchProfile(
            name=name,
            description=description,
            min_tokens=minimum,
            max_tokens=maximum,
            timeout_seconds=parse_duration(settings["timeout"]),
            witnesses=witnesses,
            prefix_tokens=tuple(prefix),
            nodes_per_depth=nodes,
        )
    return profiles


def apply_overrides(
    profile: SearchProfile, arguments: argparse.Namespace
) -> SearchProfile:
    result = profile
    if arguments.token_range is not None:
        minimum, maximum = parse_token_range(arguments.token_range)
        result = replace(result, min_tokens=minimum, max_tokens=maximum)
    if arguments.timeout is not None:
        result = replace(result, timeout_seconds=parse_duration(arguments.timeout))
    if arguments.witnesses is not None:
        if arguments.witnesses < 1:
            raise ConfigurationError("--witnesses must be at least 1")
        result = replace(result, witnesses=arguments.witnesses)
    if arguments.prefix_tokens is not None:
        result = replace(
            result, prefix_tokens=tuple(arguments.prefix_tokens.split())
        )
    if arguments.nodes_per_depth is not None:
        if arguments.nodes_per_depth < 1:
            raise ConfigurationError("--nodes-per-depth must be at least 1")
        result = replace(result, nodes_per_depth=arguments.nodes_per_depth)
    if arguments.breadth_first:
        if arguments.nodes_per_depth is not None:
            raise ConfigurationError(
                "--breadth-first and --nodes-per-depth cannot be combined"
            )
        result = replace(result, nodes_per_depth=None)
    if len(result.prefix_tokens) > result.max_tokens:
        raise ConfigurationError("prefix is longer than the maximum token count")
    return result


def engine_arguments(profile: SearchProfile, prove: int | None = None) -> list[str]:
    arguments = [
        "--max-tokens",
        str(profile.max_tokens),
        "--min-tokens",
        str(profile.min_tokens),
        "--timeout",
        f"{profile.timeout_seconds:g}",
        "--max-witnesses",
        str(profile.witnesses),
    ]
    if profile.prefix_tokens:
        arguments.extend(["--prefix-tokens", " ".join(profile.prefix_tokens)])
    if profile.nodes_per_depth is not None:
        arguments.extend(["--nodes-per-depth", str(profile.nodes_per_depth)])
    if prove is not None:
        arguments.extend(["--prove", str(prove)])
    return arguments


def profile_summary(profile: SearchProfile, action: str) -> str:
    scheduling = (
        "breadth-first"
        if profile.nodes_per_depth is None
        else f"{profile.nodes_per_depth} node"
        f"{'' if profile.nodes_per_depth == 1 else 's'} per depth"
    )
    lines = [
        f"{action} profile: {profile.name}",
        (
            f"Tokens {profile.min_tokens}..{profile.max_tokens} · "
            f"timeout {format_duration(profile.timeout_seconds)} · "
            f"{profile.witnesses} witnesses · {scheduling}"
        ),
    ]
    if profile.description:
        lines.insert(1, profile.description)
    if profile.prefix_tokens:
        lines.append(
            f"Prefix ({len(profile.prefix_tokens)}): "
            + " ".join(profile.prefix_tokens)
        )
    return "\n".join(lines)


def add_overrides(command: argparse.ArgumentParser) -> None:
    command.add_argument(
        "--tokens",
        dest="token_range",
        metavar="MIN..MAX",
        help="override the profile's complete-witness token range",
    )
    command.add_argument(
        "--timeout",
        metavar="DURATION",
        help="override the timeout; accepts values such as 90s, 30m, and 1h",
    )
    command.add_argument(
        "--witnesses",
        type=int,
        metavar="N",
        help="override the number of ambiguity families to report",
    )
    command.add_argument(
        "--prefix-tokens",
        metavar="TOKENS",
        help="override the fixed space-separated token prefix",
    )
    scheduling = command.add_mutually_exclusive_group()
    scheduling.add_argument(
        "--nodes-per-depth",
        type=int,
        metavar="N",
        help="override how many sibling frontiers a depth wave expands",
    )
    scheduling.add_argument(
        "--breadth-first",
        action="store_true",
        help="override the profile and use shortest-first scheduling",
    )
    command.add_argument(
        "--output",
        type=Path,
        metavar="FILE",
        help="write the complete report to FILE while also displaying it; "
        "{profile}, {date}, {time}, and {datetime} expand in the path "
        "(e.g. reports/{profile}-{date}.txt), and missing directories are created",
    )
    command.add_argument(
        "--dry-run",
        action="store_true",
        help="show the resolved profile without running the engine",
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
    add_overrides(prove)

    commands.add_parser("profiles", help="list available search profiles")
    commands.add_parser(
        "classes",
        help="list the terminal equivalence classes the search collapses",
    )
    return result


def _write_prelude(prelude: str, output: TextIO | None) -> None:
    print(prelude)
    print()
    sys.stdout.flush()
    if output is not None:
        output.write(prelude + "\n\n")
        output.flush()


def run_engine(
    arguments: Sequence[str], prelude: str, output_path: Path | None
) -> int:
    output: TextIO | None = None
    try:
        if output_path is not None:
            output_path.parent.mkdir(parents=True, exist_ok=True)
            output = output_path.open("w", encoding="utf-8")
        _write_prelude(prelude, output)
        process = subprocess.Popen(
            [str(ENGINE_RUNNER), "__engine", *arguments],
            stdout=subprocess.PIPE,
            text=True,
        )
        assert process.stdout is not None
        for line in process.stdout:
            sys.stdout.write(line)
            sys.stdout.flush()
            if output is not None:
                output.write(line)
                output.flush()
        return process.wait()
    except OSError as error:
        raise ConfigurationError(f"cannot run ambiguity engine: {error}") from error
    finally:
        if output is not None:
            output.close()


def list_profiles(profiles: dict[str, SearchProfile]) -> None:
    width = max(map(len, profiles))
    print("Available ambiguity-search profiles:\n")
    for name in sorted(profiles):
        profile = profiles[name]
        print(f"  {name:<{width}}  {profile.description}")
        scheduling = (
            "breadth-first"
            if profile.nodes_per_depth is None
            else f"{profile.nodes_per_depth} nodes/depth"
        )
        print(
            f"  {'':<{width}}  {profile.min_tokens}..{profile.max_tokens} tokens, "
            f"{format_duration(profile.timeout_seconds)}, "
            f"{profile.witnesses} witnesses, {scheduling}"
        )


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
            if arguments.output is None
            else expand_output_path(arguments.output, profile.name)
        )
        summary = profile_summary(profile, action)
        if output_path is not None:
            summary += f"\nReport: {output_path}"
        engine_args = engine_arguments(profile, proof_level)
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
