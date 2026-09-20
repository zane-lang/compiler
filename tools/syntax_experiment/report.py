#!/usr/bin/env python3
"""What a run is worth, and how it is written down.

The metric a variant is ranked by, the Pareto marking that says which variants
are not beaten on every axis at once, the Markdown table, and the JSON and
Markdown files the run leaves behind. A report is replaced atomically, so an
interrupted run cannot leave half a table where the previous one was.
"""

from __future__ import annotations

import argparse
from dataclasses import asdict
import json
import os
from pathlib import Path

from tools.syntax_experiment.model import KNOWN_CASES, VariantResult

def metric(result: VariantResult) -> tuple[int, int, int, int, int]:
    failed = int(result.search.error is not None or any(case.error for case in result.known_cases))
    uncertain_clean = int(result.search.families == 0 and result.search.stopped is not None)
    families = result.search.families if result.search.families is not None else 10**9
    return (
        failed,
        result.rejected_known,
        result.ambiguous_known,
        uncertain_clean,
        families + result.edit_cost,
    )


def mark_pareto(results: list[VariantResult]) -> None:
    def objectives(result: VariantResult) -> tuple[int, int, int, int, int, int]:
        failed, rejected, ambiguous, uncertain, _ = metric(result)
        families = result.search.families if result.search.families is not None else 10**9
        return failed, rejected, ambiguous, uncertain, families, result.edit_cost

    for candidate in results:
        values = objectives(candidate)
        candidate.pareto = not any(
            other is not candidate
            and all(left <= right for left, right in zip(objectives(other), values))
            and any(left < right for left, right in zip(objectives(other), values))
            for other in results
        )


def render_markdown(args: argparse.Namespace, results: list[VariantResult]) -> str:
    # --emit-only runs no search, so it has no bounds to report.
    bounds = (
        "Bounds: grammars only; no search was run."
        if args.emit_only
        else (
            f"Bounds: {args.max_tokens} tokens, {args.timeout:g}s, "
            f"{args.memory_mb:,} MiB total memory, frontier ratio "
            f"{args.max_frontier_ratio:g}, {args.max_witnesses} witnesses per variant."
        )
    )
    lines = [
        "# Zane syntax experiment report",
        "",
        bounds,
        "",
        "A Pareto mark means no tested candidate was at least as good on every measured axis. "
        "An interrupted zero-witness search is treated as uncertain, not clean.",
        "",
        "Known witnesses are respelled in each variant's own syntax before checking, so "
        "a rejection means the intended program genuinely cannot be parsed, not that an "
        "old spelling became illegal. A case a variant cannot express at all counts as "
        "rejected and is labeled explicitly.",
        "",
        "| Pareto | Variant | Edit cost | Rejected known | Ambiguous known | Families | Search stop | Seconds |",
        "|---:|---|---:|---:|---:|---:|---|---:|",
    ]
    for result in sorted(results, key=metric):
        search = result.search
        families = "error" if search.families is None else str(search.families)
        stop = search.error or search.stopped or "bound completed"
        stop = stop.replace("|", "\\|").replace("\n", " ")[:100]
        lines.append(
            f"| {'✓' if result.pareto else ''} | `{result.name}` | {result.edit_cost} | "
            f"{result.rejected_known} | {result.ambiguous_known} | {families} | {stop} | "
            f"{search.seconds:.2f} |"
        )

    lines.extend(["", "## Candidate details", ""])
    descriptions = {case.name: case.description for case in KNOWN_CASES}
    for result in sorted(results, key=metric):
        lines.extend(
            [
                f"### {result.name}",
                "",
                result.description,
                "",
                f"Transforms: `{', '.join(result.transforms) or 'none'}`",
                "",
            ]
        )
        if result.known_cases:
            lines.append("Known cases:")
            lines.append("")
            for case in result.known_cases:
                if not case.expressible:
                    lines.append(
                        f"- `{case.name}`: not expressible in this variant — "
                        f"{descriptions[case.name]}"
                    )
                    continue
                value = "error" if case.derivations is None else str(case.derivations)
                lines.append(
                    f"- `{case.name}`: {value} accepting derivations — {descriptions[case.name]}"
                )
            lines.append("")
        if result.search.sources:
            lines.append("Shortest reported examples:")
            lines.append("")
            lines.extend(f"- `{source}`" for source in result.search.sources)
            lines.append("")
        if result.search.error:
            lines.extend(["Error:", "", f"```text\n{result.search.error}\n```", ""])
    return "\n".join(lines)


def replace_atomically(path: Path, content: str) -> None:
    """Write ``content`` to ``path`` without ever leaving it truncated.

    `write_text` opens with "w", which empties the destination before the new
    content lands. That window used to be entered once, at the very end of a
    run; the reports are now rewritten after every variant, so a matrix that
    runs for hours enters it once per variant -- and a stop inside it would
    destroy the report of everything that had already finished, which is the
    one thing writing them early exists to protect. `os.replace` is atomic, so
    the destination is either the previous report or the new one. The engine
    writes its own progress files the same way.
    """
    temporary = path.with_name(f"{path.name}.new")
    try:
        temporary.write_text(content, encoding="utf-8")
        os.replace(temporary, path)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def write_reports(
    args: argparse.Namespace, results: list[VariantResult]
) -> tuple[Path, Path]:
    """Write the JSON and Markdown reports for the variants finished so far.

    Called after every variant, so the reports on disk always describe what has
    actually been run rather than appearing only once the whole matrix is over.
    The ordering is recomputed each time: the Pareto frontier and the ranking
    are properties of the set, so a partial report is the correct report for
    the variants in it, not a prefix of the final one.
    """
    ordered = sorted(results, key=metric)
    mark_pareto(ordered)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "bounds": {
            "max_tokens": args.max_tokens,
            "timeout": args.timeout,
            "memory_mb": args.memory_mb,
            "max_frontier_ratio": args.max_frontier_ratio,
            "max_witnesses": args.max_witnesses,
        },
        "known_cases": [
            {"name": case.name, "description": case.description}
            for case in KNOWN_CASES
        ],
        "results": [asdict(result) for result in ordered],
    }
    json_path = args.output.with_suffix(".json")
    markdown_path = args.output.with_suffix(".md")
    replace_atomically(json_path, json.dumps(payload, indent=2) + "\n")
    replace_atomically(markdown_path, render_markdown(args, ordered) + "\n")
    return json_path, markdown_path
