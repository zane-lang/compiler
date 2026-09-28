"""What the ambiguity front end's tests share: where the engine is built, the
environment it runs in, and the small grammar several of them search."""

import os
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[2]
ENGINE = ROOT / "_build" / "default" / "tools" / "ambiguity" / "engine" / "ambiguity_search.exe"

# A minimal grammar whose two atoms A and B are interchangeable (both reduce to
# [e] in the same contexts) so they collapse into one terminal class, while the
# unparenthesized [e PLUS e] rule is genuinely ambiguous. It exercises the
# equivalence-class machinery on a grammar small enough for the prover to finish
# instantly.
TINY_GRAMMAR = """\
%token A "a"
%token B "b"
%token PLUS "+"
%token EOF "<eof>"
%start <unit> main
%%
main: e EOF { () }
e:
  | A { () }
  | B { () }
  | e PLUS e { () }
"""


def engine_environment() -> dict[str, str] | None:
    menhir = os.environ.get("AMBIGUITY_MENHIR") or shutil.which("menhir")
    if not ENGINE.exists() or menhir is None:
        return None
    return {
        **os.environ,
        "AMBIGUITY_MENHIR": menhir,
        "AMBIGUITY_MEMORY_MB": "64",
        "AMBIGUITY_MAX_FRONTIER_RATIO": "1.0",
        "AMBIGUITY_JOBS": "1",
    }
