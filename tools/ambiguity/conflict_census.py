#!/usr/bin/env python3
"""Summarise a Menhir conflict explanations file into the ledger's census.

`docs/ambiguity/proof-obligations.md` states how many LR conflict states the
grammar has and which families they fall into. That is only true of one build:
Menhir in `--GLR` mode rewrites the grammar before it builds the automaton, so
the parser that ships and a stock `menhir --explain` disagree on both the count
and the productions each conflict reduces. This reads the explanations file
the build itself writes, `_build/default/lib/cst/parser.conflicts`, so the
census it prints is the shipped parser's.

Menhir explains each conflict state once, so the number of blocks is the number
of conflict states. Each block is keyed by what the ledger's table keys on --
the kind Menhir gives it, the lookahead tokens, and the productions it reduces
-- with the state number left out, since any grammar edit renumbers states.

Usage:
    python3 tools/ambiguity/conflict_census.py _build/default/lib/cst/parser.conflicts
"""

from __future__ import annotations

import re
import sys
from collections import Counter
from pathlib import Path


HEADER_RE = re.compile(r"^\*\* Conflict \(([^)]*)\) in state \d+\.$", re.MULTILINE)
TOKENS_RE = re.compile(r"^\*\* Tokens? involved: (.*)$", re.MULTILINE)
REDUCTION_RE = re.compile(r"reducing production\n\*\* (.*)$", re.MULTILINE)


def families(text: str) -> Counter[tuple[str, str, str]]:
    starts = [match.start() for match in HEADER_RE.finditer(text)]
    counted: Counter[tuple[str, str, str]] = Counter()
    for start, end in zip(starts, starts[1:] + [len(text)]):
        block = text[start:end]
        kind = HEADER_RE.search(block).group(1)
        tokens = TOKENS_RE.search(block).group(1).strip()
        reductions = " ; ".join(sorted(set(REDUCTION_RE.findall(block))))
        counted[(kind, tokens, reductions)] += 1
    return counted


def main() -> int:
    if len(sys.argv) != 2:
        sys.exit("usage: conflict_census.py FILE.conflicts")
    counted = families(Path(sys.argv[1]).read_text(encoding="utf-8"))
    print(f"{sum(counted.values())} conflict states")
    print()
    for (kind, tokens, reductions), states in sorted(
        counted.items(), key=lambda item: (item[0][1], item[0][2], item[0][0])
    ):
        print(f"{states:3}  {kind}  [{tokens}]  {reductions}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
