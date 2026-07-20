#!/usr/bin/env python3
"""Find short, complete ambiguities in a Menhir grammar.

The search is bounded by token count.  It asks Menhir for a fully expanded
grammar and LR(1) automaton, then explores that automaton as a GLR parser would:
all shift and reduce actions are retained.  Equivalent LR stacks are merged,
but their number of derivations is retained (and capped at two, because that is
enough to prove ambiguity).

This is a bounded search, not a proof of unambiguity.  If it finishes without a
witness, it proves only that no witness was found within the requested bounds.
"""

from __future__ import annotations

import argparse
import ast
from collections import defaultdict, deque
from dataclasses import dataclass, field
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
from typing import Mapping


Stack = tuple[int, ...]
Frontier = dict[Stack, int]
FrontierKey = tuple[tuple[Stack, int], ...]


@dataclass
class State:
    transitions: dict[str, int] = field(default_factory=dict)
    reductions: dict[str, list[tuple[str, int]]] = field(
        default_factory=lambda: defaultdict(list)
    )
    accepts: set[str] = field(default_factory=set)


@dataclass
class Automaton:
    states: dict[int, State]
    terminals: tuple[str, ...]


STATE_RE = re.compile(r"^State (\d+):$")
TRANSITION_RE = re.compile(r"^-- On (\S+) shift to state (\d+)$")
LOOKAHEAD_RE = re.compile(r"^-- On (.+)$")
REDUCTION_RE = re.compile(r"^--   reduce production (.+?) ->(?: (.*))?$")
ACCEPT_RE = re.compile(r"^--   accept (\S+)$")
TOKEN_RE = re.compile(
    r'^\s*%token(?:\s*<[^>]+>)?\s+([A-Z][A-Z0-9_]*)'
    r'(?:\s+("(?:[^"\\]|\\.)*"))?\s*$'
)


def cap_add(left: int, right: int) -> int:
    return min(2, left + right)


def key(frontier: Mapping[Stack, int]) -> FrontierKey:
    return tuple(sorted(frontier.items()))


def parse_aliases(grammar: Path) -> tuple[set[str], dict[str, str]]:
    terminals: set[str] = set()
    aliases: dict[str, str] = {}
    for line in grammar.read_text(encoding="utf-8").splitlines():
        match = TOKEN_RE.match(line)
        if not match:
            continue
        token, quoted_alias = match.groups()
        terminals.add(token)
        if quoted_alias is not None:
            try:
                aliases[token] = ast.literal_eval(quoted_alias)
            except (SyntaxError, ValueError):
                aliases[token] = quoted_alias[1:-1]
    return terminals, aliases


def run_menhir(menhir: str, grammar: Path, directory: Path) -> Path:
    expanded = directory / "expanded.mly"
    preprocess = subprocess.run(
        [menhir, "--only-preprocess-uu", str(grammar)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if preprocess.returncode != 0:
        sys.stderr.write(preprocess.stderr)
        raise RuntimeError("Menhir failed to preprocess the grammar")
    expanded.write_text(preprocess.stdout, encoding="utf-8")

    base = directory / "automaton"
    build = subprocess.run(
        [menhir, "--dump", "--base", str(base), str(expanded)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    automaton = base.with_suffix(".automaton")
    if not automaton.exists():
        sys.stderr.write(build.stderr)
        raise RuntimeError("Menhir did not produce an LR automaton")
    # Some Menhir versions exit unsuccessfully after emitting the complete
    # automaton when unresolved reduce/reduce conflicts exist.  That automaton
    # is exactly what this tool needs, so the exit status is intentionally not
    # treated as fatal here.
    return automaton


def parse_automaton(path: Path, terminals: set[str]) -> Automaton:
    states: dict[int, State] = {}
    current: State | None = None
    lookaheads: tuple[str, ...] = ()

    for line in path.read_text(encoding="utf-8").splitlines():
        if match := STATE_RE.match(line):
            current = states.setdefault(int(match.group(1)), State())
            lookaheads = ()
            continue
        if current is None:
            continue
        if match := TRANSITION_RE.match(line):
            symbol, target = match.groups()
            current.transitions[symbol] = int(target)
            lookaheads = ()
            continue
        if match := LOOKAHEAD_RE.match(line):
            lookaheads = tuple(match.group(1).split())
            continue
        if match := REDUCTION_RE.match(line):
            lhs, rhs = match.groups()
            rhs_length = 0 if not rhs else len(rhs.split())
            for token in lookaheads:
                current.reductions[token].append((lhs, rhs_length))
            continue
        if ACCEPT_RE.match(line):
            current.accepts.update(lookaheads)

    if 0 not in states:
        raise RuntimeError("could not find initial state 0 in Menhir automaton")
    return Automaton(states, tuple(sorted(terminals)))


def add_count(frontier: Frontier, stack: Stack, count: int) -> int:
    old = frontier.get(stack, 0)
    new = cap_add(old, count)
    frontier[stack] = new
    return new - old


def reduction_closure(
    automaton: Automaton, frontier: Mapping[Stack, int], lookahead: str
) -> Frontier:
    """Apply zero or more reductions while preserving derivation counts."""
    closure: Frontier = dict(frontier)
    propagated: Frontier = {}
    queue: deque[Stack] = deque(closure)

    while queue:
        stack = queue.popleft()
        available = closure[stack] - propagated.get(stack, 0)
        if available <= 0:
            continue
        propagated[stack] = closure[stack]
        state = automaton.states[stack[-1]]

        for lhs, rhs_length in state.reductions.get(lookahead, ()):
            if rhs_length >= len(stack):
                continue
            base = stack if rhs_length == 0 else stack[:-rhs_length]
            goto = automaton.states[base[-1]].transitions.get(lhs)
            if goto is None:
                continue
            reduced = base + (goto,)
            if add_count(closure, reduced, available):
                queue.append(reduced)
    return closure


def shift(
    automaton: Automaton, frontier: Mapping[Stack, int], token: str
) -> Frontier:
    shifted: Frontier = {}
    for stack, count in reduction_closure(automaton, frontier, token).items():
        target = automaton.states[stack[-1]].transitions.get(token)
        if target is not None:
            add_count(shifted, stack + (target,), count)
    return shifted


def accepted_count(automaton: Automaton, frontier: Mapping[Stack, int]) -> int:
    total = 0
    for stack, count in reduction_closure(automaton, frontier, "#").items():
        if "#" in automaton.states[stack[-1]].accepts:
            total = cap_add(total, count)
    return total


def possible_tokens(automaton: Automaton, frontier: Mapping[Stack, int]) -> set[str]:
    """Return exact lookaheads on which at least one stack has an action."""
    tokens: set[str] = set()
    terminals = set(automaton.terminals)
    for stack in frontier:
        state = automaton.states[stack[-1]]
        tokens.update(symbol for symbol in state.transitions if symbol in terminals)
        tokens.update(state.reductions)
    tokens.discard("#")
    return tokens


def render(tokens: tuple[str, ...], aliases: Mapping[str, str]) -> str:
    concrete = [aliases.get(token, f"<{token}>") for token in tokens if token != "EOF"]
    return " ".join(concrete)


def search(
    automaton: Automaton,
    max_tokens: int,
    max_frontiers: int,
    timeout: float,
    progress: bool,
) -> tuple[tuple[str, ...] | None, int, int, int, str | None]:
    initial: Frontier = {(0,): 1}
    queue: deque[tuple[tuple[str, ...], Frontier]] = deque([((), initial)])
    seen: set[FrontierKey] = {key(initial)}
    explored = 0
    started = time.monotonic()
    current_depth = -1
    deepest = 0
    stopped: str | None = None

    while queue:
        tokens, frontier = queue.popleft()
        explored += 1
        depth = len(tokens)
        deepest = max(deepest, depth)

        if progress and depth != current_depth:
            current_depth = depth
            print(
                f"depth {depth}: explored {explored:,}, queued {len(queue):,}, "
                f"unique frontiers {len(seen):,}",
                file=sys.stderr,
            )

        if accepted_count(automaton, frontier) >= 2:
            return tokens, explored, len(seen), deepest, None
        if depth >= max_tokens:
            continue
        if explored >= max_frontiers:
            stopped = f"the {max_frontiers:,}-frontier limit was reached"
            break
        if timeout and time.monotonic() - started >= timeout:
            stopped = f"the {timeout:g}-second timeout was reached"
            break

        for token in possible_tokens(automaton, frontier):
            next_frontier = shift(automaton, frontier, token)
            if not next_frontier:
                continue
            signature = key(next_frontier)
            if signature in seen:
                continue
            seen.add(signature)
            queue.append((tokens + (token,), next_frontier))

    return None, explored, len(seen), deepest, stopped


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("grammar", type=Path, help="Menhir .mly grammar")
    parser.add_argument("--menhir", default="menhir", help="Menhir executable")
    parser.add_argument(
        "--max-tokens", type=int, default=20, help="maximum tokens, including EOF"
    )
    parser.add_argument(
        "--max-frontiers", type=int, default=500_000, help="search-state limit"
    )
    parser.add_argument(
        "--timeout", type=float, default=60.0, help="time limit in seconds; 0 disables"
    )
    parser.add_argument("--quiet", action="store_true", help="hide depth progress")
    args = parser.parse_args()

    grammar = args.grammar.resolve()
    menhir = shutil.which(args.menhir)
    if menhir is None:
        parser.error(f"Menhir executable not found: {args.menhir!r}")
    if not grammar.is_file():
        parser.error(f"grammar does not exist: {grammar}")

    terminals, aliases = parse_aliases(grammar)
    try:
        with tempfile.TemporaryDirectory(prefix="zane-ambiguity-") as temporary:
            automaton_path = run_menhir(menhir, grammar, Path(temporary))
            automaton = parse_automaton(automaton_path, terminals)
            witness, explored, unique, deepest, stopped = search(
                automaton,
                max(0, args.max_tokens),
                max(1, args.max_frontiers),
                max(0.0, args.timeout),
                not args.quiet,
            )
    except (OSError, RuntimeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    if witness is None:
        if stopped is None:
            print(
                f"No complete ambiguity found through {args.max_tokens} tokens "
                f"after exploring {explored:,} frontiers ({unique:,} unique)."
            )
        else:
            print(
                f"Search stopped at depth {deepest} because {stopped}; no complete "
                f"ambiguity was found in {explored:,} explored frontiers "
                f"({unique:,} unique)."
            )
        print("This is a bounded result, not a proof of unambiguity.")
        return 0

    print("Complete ambiguity found.")
    print(f"Tokens ({len(witness)}): {' '.join(witness)}")
    print(f"Source: {render(witness, aliases)}")
    print(f"Explored {explored:,} frontiers ({unique:,} unique).")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
