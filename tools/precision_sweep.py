#!/usr/bin/env python3
"""Sweep the prover's abstraction level over one grammar and tabulate what changes.

A proof either succeeds or does not, which says nothing about *why*. When it
does not, the question is whether the blind spot is bounded — it keeps its
shape and disappears once the retained stack is wide enough — or unbounded,
growing with every level so that no level ever closes it. The two demand
opposite responses: the first is worth refining the abstraction for, the second
never will be and belongs in a written transience argument instead.

Running one level cannot tell them apart. A sweep can: a bounded blind spot
shows a falling accepting-pair count and then a proof, while an unbounded one
holds its count flat however wide the window gets.

The interesting threshold is usually predictable. The abstraction is exact
whenever a reduction pops less than the retained depth, so a conflict whose
competing reductions are W wide should stay unprovable until the level exceeds
W. Sweeping across that predicted level is what confirms or kills the theory.

Each level's own output is passed through as it arrives, under a `[level N]`
prefix, so a sweep is readable while it runs rather than a row at a time;
`--quiet` leaves only the table.

Usage:
    python3 tools/precision_sweep.py GRAMMAR.mly [--levels 1-6] [--timeout 60]
    python3 tools/precision_sweep.py --corpus even-palindrome

The corpus grammars come from `test_prover.py`, where their status is known by
construction, so they calibrate a reading of this table before it is trusted on
a grammar whose answer is the question.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from tempfile import TemporaryDirectory
from threading import Thread
from typing import TextIO


ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / "_build" / "default" / "tools" / "ambiguity" / "ambiguity_search.exe"

# Proof-mode exit statuses, matching the engine: a proof is a verdict rather
# than a success or a failure, and 2 stays reserved for a run that went wrong.
PROVEN = 0
AMBIGUOUS = 1
BROKEN = 2
NOT_PROVEN = 3

# How far past its own timeout the engine is allowed to run before the process
# is killed. Slack, not a second deadline: only a stuck process should ever
# reach it, never a level that is merely slow. It is also what a level really
# costs in the worst case, so the budget arithmetic below counts it too --
# budgeting the engine timeout alone would under-count every level.
PROCESS_SLACK_SECONDS = 120.0

# How long the readers draining a level's pipes are waited on once the level
# itself is over. On a clean exit they finish at once, because the pipes close
# with the process. A killed engine is the case this exists for: it can leave
# forked workers behind holding the inherited pipes open, and waiting on the
# readers for as long as an orphan lives would reintroduce the very hang the
# process bound is there to prevent.
PUMP_GRACE_SECONDS = 5.0

SURVEY_RE = re.compile(
    r"^Survey at level (\d+): (\d+) distinct divergence site\(s\), "
    r"(\d+) accepting abstract pair\(s\), (\d+) pairs explored(.*)$",
    re.MULTILINE,
)
EXAMPLE_RE = re.compile(r"^  \d+\. .*$", re.MULTILINE)


@dataclass
class Result:
    level: int
    status: int
    sites: int | None
    accepting: int | None
    pairs: int | None
    complete: bool | None
    seconds: float
    site_block: list[str]
    stdout: str

    @property
    def verdict(self) -> str:
        if self.status == PROVEN:
            return "PROVEN"
        if self.status == AMBIGUOUS:
            return "AMBIGUOUS"
        if self.status == NOT_PROVEN:
            return "not proven"
        return f"broken({self.status})"


def engine_environment() -> dict[str, str]:
    menhir = os.environ.get("AMBIGUITY_MENHIR") or shutil.which("menhir")
    if menhir is None:
        sys.exit(
            "menhir not found on PATH; enter the devbox shell first "
            "(devbox shell, or devbox run -- ...)"
        )
    if not ENGINE.exists():
        sys.exit(
            f"{ENGINE} not built; run: dune build tools/ambiguity/ambiguity_search.exe"
        )
    return {
        **os.environ,
        "AMBIGUITY_MENHIR": menhir,
        # Deliberately generous. A sweep exists to find the level at which a
        # blind spot closes, and a pair-limit overflow at some level would
        # report "not proven" for a reason that has nothing to do with
        # precision — reading as an unbounded blind spot that is merely an
        # under-resourced one.
        "AMBIGUITY_MEMORY_MB": os.environ.get("AMBIGUITY_MEMORY_MB", "4096"),
        "AMBIGUITY_MAX_FRONTIER_RATIO": "1.0",
        "AMBIGUITY_JOBS": "1",
    }


def site_block(stdout: str) -> list[str]:
    """The first example and the lines describing the site it was born at."""
    lines = stdout.splitlines()
    for index, line in enumerate(lines):
        if EXAMPLE_RE.fullmatch(line):
            block = [line]
            for following in lines[index + 1 :]:
                if not following.startswith("     "):
                    break
                block.append(following)
            return block
    return []


def terminate(process: subprocess.Popen[str]) -> None:
    """Kill the run and everything it forked, not just the process we started.

    The engine forks workers of its own and shells out to menhir. Killing the
    direct child alone leaves those behind: they go on burning a core and a
    full memory budget, and they hold the inherited pipes open, which is
    exactly what the readers then have to wait out. `start_new_session` on the
    spawn puts the whole run in its own process group so there is one thing to
    kill; without process groups (Windows) the direct kill is all there is.
    """
    try:
        os.killpg(os.getpgid(process.pid), signal.SIGKILL)
    except (AttributeError, OSError):
        # No process groups here, or the group is already gone.
        process.kill()
    process.wait()


def stream(
    command: list[str],
    environment: dict[str, str],
    timeout: float,
    echo: str | None,
) -> tuple[int, str, str, bool]:
    """Run ``command``, echoing its output as it arrives.

    A level is a whole proof run -- an abstract phase that can hold the entire
    timeout, then a bounded search -- and capturing it wholesale meant the
    sweep sat silent for a minute at a time and then printed one table row.
    The engine says what it is doing while it does it, so the lines are passed
    through to stderr the moment they arrive, prefixed with the level they
    belong to; stdout stays the table alone, for a caller piping it somewhere.
    They are accumulated as well, because the row itself is read back out of
    them once the level ends.

    Returns ``(status, stdout, stderr, timed_out)``. A level that outlasts its
    process bound is killed and reported rather than raising, and whatever it
    had already written is kept.
    """
    process = subprocess.Popen(
        command,
        env=environment,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        # Its own process group, so a level that has to be killed can be
        # killed whole. See [terminate].
        start_new_session=True,
    )

    def pump(handle: TextIO, collected: list[str]) -> None:
        for line in handle:
            collected.append(line)
            if echo is not None:
                sys.stderr.write(f"{echo}{line}")
                sys.stderr.flush()
        handle.close()

    out: list[str] = []
    errors: list[str] = []
    assert process.stdout is not None and process.stderr is not None
    pumps = [
        Thread(target=pump, args=(process.stdout, out), daemon=True),
        Thread(target=pump, args=(process.stderr, errors), daemon=True),
    ]
    for thread in pumps:
        thread.start()
    timed_out = False
    try:
        process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
    except BaseException:
        # A sweep runs for many minutes; an interrupt must not leave a level
        # behind still burning the machine.
        terminate(process)
        raise
    finally:
        if timed_out:
            terminate(process)
        grace = time.monotonic() + PUMP_GRACE_SECONDS
        for thread in pumps:
            thread.join(max(0.0, grace - time.monotonic()))
    # The readers are daemons, so one still blocked on an orphan's copy of a
    # pipe dies with the sweep rather than holding it up. `list.append` is
    # atomic, so reading the collected lines out from under such a thread costs
    # at worst a trailing line, never a corrupt one.
    return process.returncode, "".join(out), "".join(errors), timed_out


def run_level(
    grammar: Path,
    level: int,
    timeout: str,
    max_tokens: str,
    environment: dict[str, str],
    echo: bool = True,
) -> Result:
    started = time.monotonic()
    # `--timeout` bounds the engine's own search phases, not the process around
    # them: a hang in startup, in the menhir invocation, or in cleanup would
    # block here forever and take the rest of the sweep with it.
    process_timeout = float(timeout) + PROCESS_SLACK_SECONDS
    status, out, errors, timed_out = stream(
        [
            str(ENGINE),
            "--prove",
            str(level),
            # One example is enough: the sweep asks whether the blind spot
            # survives, and the site of the first survivor is what says why.
            "--prove-survey",
            "1",
            "--max-tokens",
            max_tokens,
            "--timeout",
            timeout,
            "--max-witnesses",
            "5",
            str(grammar),
        ],
        environment,
        process_timeout,
        f"[level {level}] " if echo else None,
    )
    if timed_out:
        return Result(
            level, BROKEN, None, None, None, None,
            time.monotonic() - started, [],
            f"the engine outlasted its process bound of {process_timeout:.0f}s "
            f"without honouring its own {timeout}s timeout\n{out}{errors}",
        )
    elapsed = time.monotonic() - started
    match = SURVEY_RE.search(out)
    if match is None:
        return Result(
            level, status, None, None, None, None, elapsed, [],
            out + errors,
        )
    return Result(
        level=level,
        status=status,
        sites=int(match.group(2)),
        accepting=int(match.group(3)),
        pairs=int(match.group(4)),
        complete="incomplete" not in match.group(5),
        seconds=elapsed,
        site_block=site_block(out),
        stdout=out + errors,
    )


def corpus_grammars() -> dict[str, str]:
    """The prover's own fixtures, whose verdicts are known by construction."""
    sys.path.insert(0, str(ROOT))
    from tools import test_prover

    return {
        "ambiguous-expression": test_prover.AMBIGUOUS_EXPRESSION,
        "dangling-else": test_prover.DANGLING_ELSE,
        "precedence-expression": test_prover.PRECEDENCE_EXPRESSION,
        "lr1-list": test_prover.LR1_LIST,
        "even-palindrome": test_prover.EVEN_PALINDROME,
        "eof-reduce-reduce": test_prover.EOF_REDUCE_REDUCE,
        "wide-reduce-reduce": test_prover.WIDE_REDUCE_REDUCE,
    }


def parse_levels(text: str) -> list[int]:
    """Levels named by a range or a comma list, refusing selections that name
    none. A reversed range yields an empty sweep, which would otherwise run no
    proof at all and report "not proven" as though it had looked."""
    if "-" in text:
        low, _, high = text.partition("-")
        levels = list(range(int(low), int(high) + 1))
        if not levels:
            raise ValueError(
                f"{text!r} runs backwards and names no level; "
                "write the lower bound first"
            )
    else:
        levels = [int(part) for part in text.split(",") if part.strip()]
    if not levels:
        raise ValueError(f"{text!r} names no level")
    if any(level < 1 for level in levels):
        raise ValueError(f"{text!r} names a level below 1")
    return levels


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "grammar", type=Path, nargs="?", help="path to a .mly grammar"
    )
    parser.add_argument(
        "--corpus",
        metavar="NAME",
        help=(
            "sweep a named grammar from the prover's test corpus instead of a "
            "file; --corpus list names them"
        ),
    )
    parser.add_argument(
        "--levels", default="1-6", help="levels to sweep, e.g. 1-6 or 2,4,6"
    )
    parser.add_argument(
        "--timeout", default="60", help="seconds per level (default: 60)"
    )
    parser.add_argument(
        "--max-tokens",
        default="12",
        help="token bound for the concretization search (default: 12)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        metavar="PATH",
        help=(
            "also write the table and its reading to this file, for a run "
            "whose terminal output is not kept"
        ),
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help=(
            "do not echo the engine's own output while a level runs; the table "
            "alone. Progress goes to stderr, so it never reaches a piped table"
        ),
    )
    parser.add_argument(
        "--budget",
        type=float,
        metavar="SECONDS",
        help=(
            "refuse to start when the worst case - one full timeout for every "
            "level - exceeds this. For a sweep running under an outer cap that "
            "kills the job, where being killed loses the reading entirely and "
            "an honest answer becomes a broken run"
        ),
    )
    arguments = parser.parse_args()

    # Both checks run before anything is opened or spawned: a sweep that cannot
    # finish should say so in a second rather than after its setup.
    try:
        levels = parse_levels(arguments.levels)
    except ValueError as error:
        parser.error(str(error))
    # The engine timeout is not what a level costs: the process outlives it by
    # the slack above, and budgeting without that under-counts every level -
    # which at eight levels is half an hour, enough to be killed by the very
    # cap this budget exists to stay inside.
    per_level = float(arguments.timeout) + PROCESS_SLACK_SECONDS
    worst_case = len(levels) * per_level
    if arguments.budget is not None and worst_case > arguments.budget:
        parser.error(
            f"{len(levels)} level(s) at {arguments.timeout}s each, plus "
            f"{PROCESS_SLACK_SECONDS:.0f}s of process slack apiece, is "
            f"{worst_case:.0f}s in the worst case, past the "
            f"{arguments.budget:.0f}s budget. Narrow --levels, lower "
            "--timeout, or raise the cap the budget was derived from."
        )

    # Rows are printed as each level finishes rather than collected and dumped
    # at the end: a sweep whose last level runs long is exactly the one whose
    # earlier rows are worth seeing, and a run killed part-way should leave the
    # levels it did finish behind it.
    report: TextIO | None = None
    if arguments.output is not None:
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        report = arguments.output.open("w", encoding="utf-8")

    def emit(text: str = "") -> None:
        print(text, flush=True)
        if report is not None:
            report.write(text + "\n")
            report.flush()

    if arguments.corpus:
        corpus = corpus_grammars()
        if arguments.corpus == "list":
            print("\n".join(sorted(corpus)))
            return 0
        if arguments.corpus not in corpus:
            sys.exit(
                f"unknown corpus grammar {arguments.corpus!r}; "
                f"try one of: {', '.join(sorted(corpus))}"
            )
        directory = TemporaryDirectory()
        arguments.grammar = Path(directory.name) / f"{arguments.corpus}.mly"
        arguments.grammar.write_text(corpus[arguments.corpus], encoding="utf-8")
    elif arguments.grammar is None:
        sys.exit("pass a grammar path, or --corpus NAME (--corpus list to see them)")
    elif not arguments.grammar.exists():
        sys.exit(f"{arguments.grammar}: no such file")

    environment = engine_environment()
    results: list[Result] = []

    emit(f"Sweeping {arguments.grammar} at {arguments.timeout}s per level.")
    emit()
    header = f"{'level':>5}  {'verdict':<10}  {'accepting':>9}  {'sites':>6}  {'pairs':>9}  {'walk':<10}  {'seconds':>7}"
    emit(header)
    emit("-" * len(header))

    for level in levels:
        result = run_level(
            arguments.grammar,
            level,
            arguments.timeout,
            arguments.max_tokens,
            environment,
            echo=not arguments.quiet,
        )
        results.append(result)
        if result.accepting is None:
            emit(
                f"{level:>5}  {result.verdict:<10}  {'-':>9}  {'-':>6}  "
                f"{'-':>9}  {'no survey':<10}  {result.seconds:>7.1f}"
            )
        else:
            walk = "complete" if result.complete else "CUT SHORT"
            emit(
                f"{level:>5}  {result.verdict:<10}  {result.accepting:>9}  "
                f"{result.sites:>6}  {result.pairs:>9}  {walk:<10}  "
                f"{result.seconds:>7.1f}"
            )
        # A proof is the end of the sweep: every wider window proves too, and
        # the levels above it only cost time.
        if result.status == PROVEN:
            break

    emit()
    # Checked before any trend: a level that never reached a verdict has
    # counted nothing, and reading a trend across the levels that did would
    # report an under-resourced or broken run as a property of the grammar.
    broken = [
        r for r in results if r.status not in (PROVEN, AMBIGUOUS, NOT_PROVEN)
    ]
    if broken:
        emit(
            "BROKEN: "
            + ", ".join(f"level {r.level}" for r in broken)
            + " reached no verdict, so this run went wrong rather than the "
            "grammar being unproven. The engine's output for the first is "
            "below."
        )
        emit()
        for line in broken[0].stdout.splitlines()[:20]:
            emit(line)
        return BROKEN

    proved = next((r for r in results if r.status == PROVEN), None)
    if proved is not None:
        emit(
            f"BOUNDED: the blind spot closes at level {proved.level}. "
            "Refining the abstraction to that depth — globally, or only along "
            "a counterexample's chain — is enough to prove this grammar."
        )
        return 0

    if any(r.status == AMBIGUOUS for r in results):
        emit(
            "AMBIGUOUS: a concrete ambiguous sentence was found, so no level "
            "will ever prove this grammar. Fix the grammar."
        )
        return AMBIGUOUS

    cut = [r for r in results if r.complete is False]
    if cut:
        emit(
            "INCONCLUSIVE: "
            + ", ".join(f"level {r.level}" for r in cut)
            + " did not finish walking the abstract space, so their counts are "
            "a floor rather than a total. Raise --timeout or "
            "AMBIGUITY_MEMORY_MB before reading the trend."
        )

    counts = [r.accepting for r in results if r.accepting is not None]
    if counts and len(set(counts)) == 1 and not cut:
        emit(
            f"FLAT: {counts[0]} accepting pair(s) at every level swept, with "
            "every walk complete. That is the signature of an unbounded blind "
            "spot — one that defeats a wider window by taking a longer "
            "sentence — for which no level will ever prove the grammar. Check "
            "the site below against the widest competing reduction: if the "
            "sweep never reached a level above it, the theory is untested "
            "rather than refuted."
        )
    elif counts and not cut:
        emit(
            "FALLING: the accepting-pair count moves with the level, so the "
            "blind spot is sensitive to the window. Extend --levels past the "
            "widest competing reduction before concluding anything."
        )

    last = next((r for r in reversed(results) if r.site_block), None)
    if last is not None:
        emit()
        emit(f"Surviving site at level {last.level}:")
        for line in last.site_block:
            emit(line)
    return NOT_PROVEN


if __name__ == "__main__":
    sys.exit(main())
