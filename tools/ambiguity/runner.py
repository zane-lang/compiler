#!/usr/bin/env python3
"""Running the engine and showing what it says while it says it.

Turning a profile into the engine's flags, starting it, and streaming its
output to the terminal and into the saved report at the same time. A search can
run for an hour, so nothing here waits for the process to finish before
printing: the report file is written line by line, and the engine's stderr is
folded into stdout so its diagnostics land in the report beside the results
they explain.
"""

from __future__ import annotations

from pathlib import Path
import subprocess
import sys
from typing import Sequence, TextIO

from tools.ambiguity.profiles import SETTINGS, ConfigurationError, SearchProfile


ROOT = Path(__file__).resolve().parents[2]
# The private entry point of the shell wrapper, which loads the machine
# configuration and builds the executable before handing over to it.
ENGINE_RUNNER = ROOT / "dev" / "bin" / "ambiguity"

def engine_arguments(
    profile: SearchProfile,
    prove: int | None = None,
    survey: int = 0,
    refine: int = 0,
    refine_rounds: int = 0,
    retire: int = 0,
    trace: bool = False,
) -> list[str]:
    arguments: list[str] = []
    for setting in SETTINGS:
        if setting.to_engine_args is not None:
            arguments.extend(setting.to_engine_args(profile))
    if prove is not None:
        arguments.extend(["--prove", str(prove)])
    # A survey is a property of one invocation rather than of a saved search
    # intent, so it stays a flag and never becomes a profile key. Refinement is
    # the same: it says how hard to push on one run, not what the run is for.
    if survey > 0:
        arguments.extend(["--prove-survey", str(survey)])
    if refine > 0:
        arguments.extend(["--prove-refine", str(refine)])
        if refine_rounds > 0:
            arguments.extend(["--prove-refine-rounds", str(refine_rounds)])
        if retire > 0:
            arguments.extend(["--prove-retire", str(retire)])
    if trace:
        arguments.append("--prove-trace")
    return arguments


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
        # The engine's diagnostics (memory budget, menhir failures, the reason a
        # search stopped) go to stderr, so they are folded into stdout: they
        # belong in the saved report next to the results they explain, and the
        # terminal still shows them interleaved in order.
        process = subprocess.Popen(
            [str(ENGINE_RUNNER), "__engine", *arguments],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        try:
            assert process.stdout is not None
            for line in process.stdout:
                sys.stdout.write(line)
                sys.stdout.flush()
                if output is not None:
                    output.write(line)
                    output.flush()
            return process.wait()
        except BaseException:
            # A search can run for an hour; if streaming fails or the user
            # interrupts, the engine must not be left running unattended.
            process.kill()
            process.wait()
            raise
        finally:
            if process.stdout is not None:
                process.stdout.close()
    except OSError as error:
        raise ConfigurationError(f"cannot run ambiguity engine: {error}") from error
    finally:
        if output is not None:
            output.close()
