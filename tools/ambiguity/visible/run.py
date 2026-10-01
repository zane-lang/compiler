"""Build an exact accepted-parse grammar, prove it, and verify its certificate."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

from .verify import verify

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(grammar: Path, output: Path, menhir: str | None, stock: bool = False,
        seconds: int = 300, max_nodes: int = 100000) -> int:
    grammar = grammar.resolve()
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    executable = menhir or os.environ.get("AMBIGUITY_MENHIR") or shutil.which("menhir")
    if not executable:
        raise ValueError("Menhir is required; supply --menhir or AMBIGUITY_MENHIR")
    env = {**os.environ, "PYTHONHASHSEED": "0"}
    source_hash = digest(grammar)
    started = time.monotonic()
    log = output / "run.log"
    certificate = output / "certificate.json"
    certificate.unlink(missing_ok=True)
    manifest_path = output / "manifest.json"
    manifest_path.unlink(missing_ok=True)
    with log.open("w") as stream:
        def invoke(args, stdout=None):
            stream.write("COMMAND " + json.dumps([str(a) for a in args]) + "\n")
            stream.flush()
            try:
                return subprocess.run([str(a) for a in args], env=env,
                                  stdout=stdout or stream, stderr=stream,
                                      timeout=seconds).returncode
            except subprocess.TimeoutExpired:
                stream.write("NOT PROVEN: stage time limit\n")
                return 3

        version = subprocess.run([executable, "--version"], capture_output=True, text=True, check=True).stdout.strip()
        # Both commands read the original grammar with the same backend.
        # The erased expansion supplies production identities; the dump keeps
        # the actual GLR numbering, nullable rewrite, and retained conflicts.
        backend = ["--no-code-generation"] if stock else ["--GLR"]
        expanded = output / "expanded.mly"
        with expanded.open("w") as target:
            status = invoke([executable, *backend, "--only-preprocess-uu", grammar], target)
        if status:
            raise ValueError("Menhir preprocessing failed; see run.log")
        base = output / "parser"
        if invoke([executable, *backend, "--dump", "--base", base, grammar]):
            raise ValueError("Menhir automaton generation failed; see run.log")
        stages = [
            ("lr.py", [base.with_suffix(".automaton"), output / "context.y", expanded, "--minimize"]),
            ("angles.py", [output / "context.y", output / "angles.y"]),
            ("lookahead.py", [output / "angles.y", output / "exact.y", "--bracket-groups"]),
            ("factor.py", [output / "exact.y", output / "factored.y"]),
            ("prove.py", [output / "factored.y", max_nodes, seconds, certificate]),
        ]
        for worker, arguments in stages:
            status = invoke([sys.executable, HERE / worker, *arguments])
            if status:
                if worker == "prove.py" and status == 1 and "\nAMBIGUOUS " in log.read_text():
                    print("AMBIGUOUS: exact visible-stack model accepts at least two parses.")
                    return 1
                print(f"NOT PROVEN: {worker} did not complete (exit {status}); see {log}")
                return 3
    checked = verify(certificate, output / "factored.y")
    if digest(grammar) != source_hash:
        raise ValueError("grammar changed during proof generation")
    # Source identity is checked again after the run, so an edited grammar
    # cannot accidentally inherit the certificate of an earlier snapshot.
    files = [expanded, base.with_suffix(".automaton"), output / "context.y",
             output / "context.guards.tsv", output / "angles.y", output / "angles.guards.tsv",
             output / "angles.angle-certificate.json", output / "exact.y",
             output / "factored.y", certificate]
    manifest = {
        "schema": 1, "verdict": "PROVEN_UNAMBIGUOUS", "mode": "stock" if stock else "GLR",
        "menhir": version, "source": str(grammar), "source_sha256": digest(grammar),
        "files": {p.name: digest(p) for p in files},
        "implementation": {p.name: digest(p) for p in sorted(HERE.glob("*.py"))},
        "certificate_check": checked, "elapsed_seconds": round(time.monotonic() - started, 3),
        "scope": "Accepted syntactic derivations after Menhir precedence resolution; semantic actions erased",
    }
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"PROVEN UNAMBIGUOUS ({manifest['mode']}): {checked['configurations']} configurations, "
          f"{checked['frames']} frames; certificate independently verified.")
    print(f"Certificate: {certificate}")
    return 0
