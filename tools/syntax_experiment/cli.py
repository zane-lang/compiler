#!/usr/bin/env python3
"""Compare small, controlled syntax changes with the ambiguity search.

Each variant is an explicit composition of named grammar transformations.  The
harness emits temporary Menhir grammars, replays known ambiguity witnesses, runs
the bounded complete-ambiguity search, and writes JSON and Markdown reports.

The result is experimental evidence, not a proof that a grammar is unambiguous.

This file is the frontend: it parses the command line, selects the variants to
run, and hands each to the modules beside it. [model] holds the variants
themselves, [transforms] the grammar rewrites they compose, [runner] the
processes, and [report] what is written down.
"""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import math
import os
from pathlib import Path
import shlex
import sys
import tempfile

# Run as a script -- `dev/bin/syntax-experiment` execs this file by path --
# sys.path starts at this directory rather than the repository root, so the
# modules beside it are not reachable by package path until the root is on it.
# Imported as `tools.syntax_experiment.cli` the root is already there and this
# is a no-op.
ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.syntax_experiment.model import (  # noqa: E402
    VARIANTS,
    SearchResult,
    Variant,
    VariantResult,
)
from tools.syntax_experiment.runner import evaluate_variant  # noqa: E402
from tools.syntax_experiment.report import write_reports  # noqa: E402

def select_variants(names: list[str] | None) -> list[Variant]:
    by_name = {variant.name: variant for variant in VARIANTS}
    if not names:
        return list(VARIANTS)
    unknown = sorted(set(names) - by_name.keys())
    if unknown:
        raise ValueError(f"unknown variants: {', '.join(unknown)}")
    return [by_name[name] for name in names]


def parser() -> argparse.ArgumentParser:
    # Named for the command that runs it (dev/bin/syntax-experiment) rather
    # than for this file, which argparse would otherwise call `cli.py`.
    result = argparse.ArgumentParser(prog="syntax-experiment", description=__doc__)
    result.add_argument("grammar", nargs="?", type=Path, default=Path("lib/cst/parser.mly"))
    result.add_argument("--variant", action="append", help="variant to run; repeatable")
    result.add_argument("--list", action="store_true", help="list variants and exit")
    result.add_argument("--emit-only", action="store_true", help="only materialize grammars")
    result.add_argument("--emit-dir", type=Path, help="keep generated grammars in this directory")
    result.add_argument(
        "--search-command",
        default="_build/default/tools/ambiguity/ambiguity_search.exe",
        help="command prefix used to invoke the ambiguity search; the default"
        " expects a prior `dune build tools/ambiguity/ambiguity_search.exe`",
    )
    result.add_argument("--max-tokens", type=int)
    result.add_argument("--timeout", type=float)
    result.add_argument("--max-witnesses", type=int)
    result.add_argument("--skip-known", action="store_true")
    result.add_argument(
        "--quiet",
        action="store_true",
        help=(
            "do not echo each search's own output while it runs; the per-variant"
            " status lines and the reports only"
        ),
    )
    result.add_argument(
        "--output",
        type=Path,
        default=Path("_build/syntax-experiment/report"),
        help="report path without extension",
    )
    return result


def load_machine_config(args: argparse.Namespace, cli: argparse.ArgumentParser) -> None:
    names = (
        "AMBIGUITY_MEMORY_MB",
        "AMBIGUITY_MAX_FRONTIER_RATIO",
        "AMBIGUITY_JOBS",
        "AMBIGUITY_MENHIR",
    )
    missing = [name for name in names if not os.environ.get(name)]
    if missing:
        cli.error(f"missing machine configuration: {', '.join(missing)}")
    args.menhir = os.environ["AMBIGUITY_MENHIR"]
    try:
        args.memory_mb = int(os.environ["AMBIGUITY_MEMORY_MB"])
        args.max_frontier_ratio = float(os.environ["AMBIGUITY_MAX_FRONTIER_RATIO"])
        args.jobs = int(os.environ["AMBIGUITY_JOBS"])
    except ValueError:
        cli.error(
            "invalid AMBIGUITY_MEMORY_MB, AMBIGUITY_MAX_FRONTIER_RATIO, "
            "or AMBIGUITY_JOBS"
        )


def validate_args(args: argparse.Namespace, cli: argparse.ArgumentParser) -> None:
    if not args.grammar.is_file():
        cli.error(f"grammar does not exist: {args.grammar}")
    search_words = shlex.split(args.search_command)
    if not search_words:
        cli.error("--search-command must not be empty")
    executable = search_words[0]
    if not args.emit_only and os.path.dirname(executable) and not Path(executable).is_file():
        cli.error(
            f"search executable does not exist: {executable};"
            " run `dune build tools/ambiguity/ambiguity_search.exe` first"
        )
    # --emit-only produces grammars and nothing else, so without a directory to
    # keep them in they would be written to a temporary directory and deleted
    # again before the command returns — reporting variants as "generated" with
    # nothing on disk to show for it.
    if args.emit_only and args.emit_dir is None:
        cli.error("--emit-only requires --emit-dir to say where to keep the grammars")
    # --emit-only materializes grammars and returns without running a search,
    # so the search bounds do not apply to it.
    if not args.emit_only:
        missing = [
            name
            for name, value in (
                ("--max-tokens", args.max_tokens),
                ("--timeout", args.timeout),
                ("--max-witnesses", args.max_witnesses),
            )
            if value is None
        ]
        if missing:
            cli.error(f"required for experiments: {', '.join(missing)}")
        if args.max_tokens < 0:
            cli.error("--max-tokens must be at least 0")
        if args.timeout < 0:
            cli.error("--timeout must be non-negative")
        if args.max_witnesses < 1:
            cli.error("the witness limit must be at least 1")
    if args.memory_mb < 1:
        cli.error("AMBIGUITY_MEMORY_MB must be at least 1")
    if not math.isfinite(args.max_frontier_ratio) or args.max_frontier_ratio <= 0:
        cli.error("AMBIGUITY_MAX_FRONTIER_RATIO must be finite and greater than 0")
    if args.jobs < 1:
        cli.error("AMBIGUITY_JOBS must be at least 1")


def main() -> int:
    cli = parser()
    args = cli.parse_args()
    if args.list:
        for variant in VARIANTS:
            transforms = ", ".join(variant.transforms) or "baseline"
            print(f"{variant.name:52} cost={variant.edit_cost}  {transforms}")
            print(f"  {variant.description}")
        return 0
    load_machine_config(args, cli)
    validate_args(args, cli)
    try:
        variants = select_variants(args.variant)
    except ValueError as error:
        cli.error(str(error))
    args.concurrent_searches = min(args.jobs, len(variants))
    args.search_jobs = max(1, args.jobs // args.concurrent_searches)
    if args.memory_mb < args.concurrent_searches:
        cli.error(
            "AMBIGUITY_MEMORY_MB must provide at least 1 MiB per concurrent search"
        )

    source = args.grammar.read_text(encoding="utf-8")
    temporary: tempfile.TemporaryDirectory[str] | None = None
    if args.emit_dir:
        directory = args.emit_dir
        directory.mkdir(parents=True, exist_ok=True)
    else:
        temporary = tempfile.TemporaryDirectory(prefix="zane-syntax-")
        directory = Path(temporary.name)

    try:
        results: list[VariantResult] = []
        with ThreadPoolExecutor(max_workers=args.jobs) as executor:
            futures = {
                executor.submit(evaluate_variant, args, source, variant, directory): variant
                for variant in variants
            }
            for future in as_completed(futures):
                variant = futures[future]
                try:
                    result = future.result()
                except Exception as error:  # keep other experiments running
                    search = SearchResult(
                        None, None, None, None, None, None, [], 0.0, str(error)
                    )
                    result = VariantResult(
                        variant.name,
                        variant.description,
                        list(variant.transforms),
                        variant.edit_cost,
                        [],
                        search,
                        0,
                        0,
                    )
                results.append(result)
                status = "generated" if args.emit_only else (
                    f"{result.search.families} families"
                    if result.search.error is None
                    else "error"
                )
                print(f"[{len(results):02d}/{len(variants):02d}] {variant.name}: {status}", file=sys.stderr)
                # Rewritten after every variant rather than once at the end. A
                # full matrix is hours of search, and a run that is killed or
                # interrupted part-way used to leave nothing at all behind --
                # the variants that had finished were only ever in memory.
                write_reports(args, results)

        json_path, markdown_path = write_reports(args, results)
        print(f"JSON: {json_path}")
        print(f"Markdown: {markdown_path}")
        return 0 if all(result.search.error is None for result in results) else 2
    finally:
        if temporary is not None:
            temporary.cleanup()


if __name__ == "__main__":
    raise SystemExit(main())
