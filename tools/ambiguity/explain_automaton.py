#!/usr/bin/env python3
"""Dump Menhir's LR automaton and conflict explanations for a grammar.

`docs/ambiguity.md` calls `menhir --explain` the obligation ledger, but reading
it has to be done the same way the prover does or the two disagree. The prover
expands parameterized rules first, with `--only-preprocess-uu`, which is why a
proof report cites productions under their expanded names -- `loption_generics_`
rather than `loption(generics)`. Running Menhir directly on the unexpanded
grammar produces different state numbers and different production names, so a
state number from a proof report would name a different state here.

This runs the same two steps in the same order, so a state number printed by
`ambiguity prove` selects the state that produced it.

Usage:
    python3 tools/ambiguity/explain_automaton.py --state 27
    python3 tools/ambiguity/explain_automaton.py --conflicts
    python3 tools/ambiguity/explain_automaton.py --search list_verb_type_suffix_
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from tempfile import TemporaryDirectory


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_GRAMMAR = ROOT / "lib" / "cst" / "parser.mly"
STATE_RE = re.compile(r"^State (\d+):$")


def menhir_binary() -> str:
    found = os.environ.get("AMBIGUITY_MENHIR") or shutil.which("menhir")
    if found is None:
        sys.exit(
            "menhir not found on PATH; enter the devbox shell first "
            "(devbox shell, or devbox run -- ...)"
        )
    return found


def build(menhir: str, grammar: Path, directory: Path) -> tuple[Path, Path]:
    """Expand, then dump. Returns the .automaton and .conflicts paths."""
    expanded = directory / "expanded.mly"
    with expanded.open("w", encoding="utf-8") as handle:
        completed = subprocess.run(
            [menhir, "--only-preprocess-uu", str(grammar)],
            stdout=handle,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
    if completed.returncode != 0:
        sys.exit(f"menhir failed to preprocess {grammar}:\n{completed.stderr}")

    base = directory / "automaton"
    # A grammar with conflicts makes Menhir exit non-zero while still writing
    # both files, and a grammar with conflicts is the whole subject here, so
    # the status is ignored and the files are checked instead.
    subprocess.run(
        [menhir, "--dump", "--explain", "--base", str(base), str(expanded)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    automaton = base.with_suffix(".automaton")
    if not automaton.exists():
        sys.exit("menhir did not produce an LR automaton")
    return automaton, base.with_suffix(".conflicts")


def state_block(automaton: Path, wanted: int) -> list[str]:
    lines = automaton.read_text(encoding="utf-8").splitlines()
    block: list[str] = []
    inside = False
    for line in lines:
        match = STATE_RE.match(line)
        if match is not None:
            if inside:
                break
            inside = int(match.group(1)) == wanted
        if inside:
            block.append(line)
    return block


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="explain_automaton.py", description=__doc__
    )
    parser.add_argument("--grammar", type=Path, default=DEFAULT_GRAMMAR)
    parser.add_argument(
        "--state",
        type=int,
        action="append",
        default=[],
        metavar="N",
        help="print this state's items and actions; repeatable",
    )
    parser.add_argument(
        "--conflicts",
        action="store_true",
        help="print Menhir's conflict explanations, the obligation ledger",
    )
    parser.add_argument(
        "--search",
        metavar="TEXT",
        help="print every state whose block mentions TEXT",
    )
    arguments = parser.parse_args()

    if not arguments.state and not arguments.conflicts and not arguments.search:
        parser.error("pass --state N, --conflicts, or --search TEXT")

    menhir = menhir_binary()
    with TemporaryDirectory() as directory:
        automaton, conflicts = build(menhir, arguments.grammar, Path(directory))

        # Flushed block by block. A --search over Zane's automaton prints
        # hundreds of states, and through a pipe -- into `less`, into a file --
        # a block-buffered stdout would hold all of them back until the command
        # was over.
        for wanted in arguments.state:
            block = state_block(automaton, wanted)
            if not block:
                print(f"No State {wanted} in the automaton.")
            else:
                print("\n".join(block))
            print(flush=True)

        if arguments.search:
            text = automaton.read_text(encoding="utf-8")
            current: list[str] = []
            for line in text.splitlines():
                if STATE_RE.match(line):
                    if any(arguments.search in one for one in current):
                        print("\n".join(current))
                        print(flush=True)
                    current = []
                current.append(line)
            if any(arguments.search in one for one in current):
                print("\n".join(current))
                print(flush=True)

        if arguments.conflicts:
            if conflicts.exists():
                print(conflicts.read_text(encoding="utf-8"), end="", flush=True)
            else:
                print("Menhir reported no conflicts.", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
