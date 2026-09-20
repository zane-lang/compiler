#!/usr/bin/env python3
"""Running one variant: the grammar it implies, the cases it must still parse,
and the search that looks for an ambiguity in it.

This is where processes live. A search can run for minutes and print as it
goes, so its output is pumped rather than collected at the end, a run that
stops making progress is killed with the grace period its children need, and
the engine's own report lines are parsed back into a result record.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
from threading import Thread
import time
from typing import TextIO

from tools.syntax_experiment.model import (
    KNOWN_CASES,
    CaseResult,
    KnownCase,
    SearchResult,
    Variant,
    VariantResult,
    case_tokens,
)
from tools.syntax_experiment.transforms import apply_variant

# Outside the engine's own exit codes (0 unambiguous, 1 ambiguous), so a killed
# process is reported as a failed case rather than mistaken for a result.
EXIT_TIMED_OUT = 124

# How long the readers draining a search's pipes are waited on once the search
# is over. On a clean exit they finish at once, with the pipes.
PUMP_GRACE_SECONDS = 5.0

# What the engine starts a progress line with.
PROGRESS_MARKER = "●"

DERIVATIONS_RE = re.compile(r"Accepting derivations: (\d+)")
FAMILIES_RE = re.compile(r"Found (\d+) complete ambiguity")
EXPLORED_RE = re.compile(r"Explored (\d+) frontiers \((\d+) unique\); (\d+) conflict seeds")
NO_WITNESS_RE = re.compile(
    r"(?:after exploring|found in) (\d+) (?:explored )?frontiers \((\d+) unique\)"
)
# Every search now names how it ended, exhaustion included, so these match on
# each run rather than only on a curtailed one. `stopped` still means "ended
# early" to the rest of this tool -- uncertain_clean and the report's stop
# column both read it that way -- so the exhaustion reason is recognised here
# and mapped back to None, keeping "stopped" about limits rather than about
# whether the engine bothered to explain itself.
COMPLETED_REASON = "the search space within the token bound was exhausted"
DEPTH_RE = re.compile(r"Search ended at depth (\d+)")
STOPPED_RE = re.compile(r"Search ended at depth \d+ because ([^.;]+)")
SOURCE_RE = re.compile(r"^\s*Source: (.*)$", re.MULTILINE)


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


def run_process(
    command: list[str],
    env: dict[str, str] | None = None,
    timeout: float | None = None,
    echo: str | None = None,
) -> tuple[int, str, str, float]:
    """Run ``command``, returning ``(code, stdout, stderr, seconds)``.

    ``timeout`` is a process-level backstop, not the search's own budget: the
    engine enforces ``--timeout`` itself, but a wedged process would otherwise
    block its worker forever. On expiry the child is killed and the call
    reports a non-zero status rather than raising.

    ``echo`` is a prefix under which every line is passed through to stderr as
    it arrives. A search is minutes long and says what it is doing while it
    runs; capturing it wholesale meant none of that was visible until the
    variant was over. Several variants run at once, which is what the prefix is
    for: it names the variant each line came from.
    """
    started = time.monotonic()
    process = subprocess.Popen(
        command,
        text=True,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        # Its own process group, so a search that has to be killed can be
        # killed whole -- searches here really do run with AMBIGUITY_JOBS
        # above one, so the engine really does fork. See [terminate].
        start_new_session=True,
    )

    def pump(handle: TextIO, collected: list[str]) -> None:
        for line in handle:
            collected.append(line)
            if echo is not None:
                # One write per line: two threads per search, several searches
                # at once, and interleaved halves of a line would be worse than
                # no echo at all.
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
        terminate(process)
        raise
    finally:
        if timed_out:
            terminate(process)
        # A killed engine can leave forked workers holding the inherited pipes
        # open, so the readers get a grace period rather than an unbounded
        # join: waiting on them for as long as an orphan lives would be the
        # very hang the process bound exists to prevent. They are daemons, so
        # one still blocked dies with the run.
        grace = time.monotonic() + PUMP_GRACE_SECONDS
        for thread in pumps:
            thread.join(max(0.0, grace - time.monotonic()))
    if timed_out:
        return (
            EXIT_TIMED_OUT,
            "".join(out),
            (
                "".join(errors)
                + f"search did not exit within {timeout:.0f}s and was killed"
            ),
            time.monotonic() - started,
        )
    return (
        process.returncode,
        "".join(out),
        "".join(errors),
        time.monotonic() - started,
    )


def without_progress(text: str) -> str:
    """``text`` with the engine's progress lines dropped.

    They are on stderr, where a failed run looks for its explanation, and a
    hundred heartbeats ahead of the real message would bury it.
    """
    return "".join(
        line
        for line in text.splitlines(keepends=True)
        if not line.startswith(PROGRESS_MARKER)
    )


def process_timeout(args: argparse.Namespace) -> float:
    """Generous bound around the engine's own ``--timeout``.

    Startup, menhir invocation, and writing results all happen outside the
    searched budget, so allow double the budget plus a fixed minute.
    """
    return args.timeout * 2 + 60


def base_command(args: argparse.Namespace, grammar: Path) -> list[str]:
    return [*shlex.split(args.search_command), str(grammar)]


def check_case(args: argparse.Namespace, grammar: Path, case: KnownCase, variant: Variant) -> CaseResult:
    tokens = case_tokens(case, variant)
    if tokens is None:
        return CaseResult(case.name, None, 0.0, expressible=False)
    command = [*base_command(args, grammar), "--check-tokens", tokens]
    code, stdout, stderr, seconds = run_process(command, timeout=process_timeout(args))
    match = DERIVATIONS_RE.search(stdout)
    if code not in {0, 1} or match is None:
        message = (
            without_progress(stderr) or stdout or f"search exited with status {code}"
        ).strip()
        return CaseResult(case.name, None, seconds, message, tokens)
    return CaseResult(case.name, int(match.group(1)), seconds, tokens=tokens)


def search_variant(args: argparse.Namespace, grammar: Path) -> SearchResult:
    # Several variants may run concurrently. Give each search an equal share
    # so AMBIGUITY_MEMORY_MB remains a total budget for the whole command.
    search_memory_mb = args.memory_mb // args.concurrent_searches
    environment = os.environ.copy()
    environment.update(
        {
            "AMBIGUITY_MEMORY_MB": str(search_memory_mb),
            "AMBIGUITY_MAX_FRONTIER_RATIO": str(args.max_frontier_ratio),
            "AMBIGUITY_JOBS": str(args.search_jobs),
            "AMBIGUITY_MENHIR": args.menhir,
        }
    )
    command = [
        *base_command(args, grammar),
        "--max-tokens",
        str(args.max_tokens),
        "--timeout",
        str(args.timeout),
        "--max-witnesses",
        str(args.max_witnesses),
    ]
    code, stdout, stderr, seconds = run_process(
        command,
        env=environment,
        timeout=process_timeout(args),
        echo=None if args.quiet else f"[{grammar.stem}] ",
    )
    if code not in {0, 1}:
        message = (
            without_progress(stderr) or stdout or f"search exited with status {code}"
        ).strip()
        return SearchResult(None, None, None, None, None, None, [], seconds, message)
    return parse_search_output(stdout, seconds)


def parse_search_output(stdout: str, seconds: float) -> SearchResult:
    """Read one search report into a `SearchResult`.

    Separate from running the search so the report contract - in particular
    what a missing termination line has to mean - can be exercised without a
    built engine.
    """
    family_match = FAMILIES_RE.search(stdout)
    families = int(family_match.group(1)) if family_match else 0
    explored_match = EXPLORED_RE.search(stdout)
    no_witness_match = NO_WITNESS_RE.search(stdout)
    if explored_match:
        explored, unique, seeds = map(int, explored_match.groups())
    elif no_witness_match:
        explored, unique = map(int, no_witness_match.groups())
        seeds = None
    else:
        explored = unique = seeds = None
    depth_match = DEPTH_RE.search(stdout)
    stopped_match = STOPPED_RE.search(stdout)
    if depth_match is None or stopped_match is None:
        # Every search states how it ended, so output without that line did not
        # come from an engine holding to this contract -- a stale report, or a
        # run that died before printing one. Reading a missing reason as "no
        # reason" would hand it to metric() as a confidently clean result, which
        # is the one conclusion the absent line cannot support. Fail closed.
        return SearchResult(
            None,
            None,
            None,
            None,
            None,
            None,
            [],
            seconds,
            "search output is missing the termination line",
        )
    stopped_reason = stopped_match.group(1)
    if stopped_reason == COMPLETED_REASON:
        stopped_reason = None
    return SearchResult(
        families,
        explored,
        unique,
        seeds,
        int(depth_match.group(1)),
        stopped_reason,
        SOURCE_RE.findall(stdout)[:5],
        seconds,
    )


def evaluate_variant(
    args: argparse.Namespace, source: str, variant: Variant, directory: Path
) -> VariantResult:
    grammar = directory / f"{variant.name}.mly"
    try:
        grammar.write_text(apply_variant(source, variant), encoding="utf-8")
    except ValueError as error:
        failed = SearchResult(None, None, None, None, None, None, [], 0.0, str(error))
        return VariantResult(
            variant.name,
            variant.description,
            list(variant.transforms),
            variant.edit_cost,
            [],
            failed,
            0,
            0,
        )

    if args.emit_only:
        empty = SearchResult(None, None, None, None, None, None, [], 0.0)
        return VariantResult(
            variant.name,
            variant.description,
            list(variant.transforms),
            variant.edit_cost,
            [],
            empty,
            0,
            0,
        )

    cases = (
        []
        if args.skip_known
        else [check_case(args, grammar, case, variant) for case in KNOWN_CASES]
    )
    search = search_variant(args, grammar)
    rejected = sum(not case.expressible or case.derivations == 0 for case in cases)
    ambiguous = sum(
        case.derivations is not None and case.derivations >= 2 for case in cases
    )
    return VariantResult(
        variant.name,
        variant.description,
        list(variant.transforms),
        variant.edit_cost,
        cases,
        search,
        rejected,
        ambiguous,
    )
