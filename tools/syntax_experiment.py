#!/usr/bin/env python3
"""Compare small, controlled syntax changes with the ambiguity search.

Each variant is an explicit composition of named grammar transformations.  The
harness emits temporary Menhir grammars, replays known ambiguity witnesses, runs
the bounded complete-ambiguity search, and writes JSON and Markdown reports.

The result is experimental evidence, not a proof that a grammar is unambiguous.
"""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import asdict, dataclass, replace
import json
import math
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import time
from typing import Callable, Iterable


Transform = Callable[[str], str]


@dataclass(frozen=True)
class Variant:
    name: str
    description: str
    transforms: tuple[str, ...]
    edit_cost: int


@dataclass(frozen=True)
class Spelling:
    """How a variant spells the surface syntax the known cases depend on.

    Call and grouping delimiters are (opening, closing) token-name pairs; a
    ``None`` group means the variant removed general grouping.  Separators and
    terminators are token sequences placed between or after statements and
    after top-level declarations.
    """

    group: tuple[tuple[str, ...], tuple[str, ...]] | None
    named_call: tuple[tuple[str, ...], tuple[str, ...]]
    computed_call: tuple[tuple[str, ...], tuple[str, ...]]
    computed_call_statement: bool
    stat_separator: tuple[str, ...]
    stat_terminator: tuple[str, ...]
    decl_terminator: tuple[str, ...]


BASELINE_SPELLING = Spelling(
    group=(("LPAREN",), ("RPAREN",)),
    named_call=(("LPAREN",), ("RPAREN",)),
    computed_call=(("LPAREN",), ("RPAREN",)),
    computed_call_statement=True,
    stat_separator=(),
    stat_terminator=(),
    decl_terminator=(),
)


@dataclass(frozen=True)
class KnownCase:
    name: str
    description: str
    spell: Callable[[Spelling], list[str] | None]


@dataclass
class CaseResult:
    name: str
    derivations: int | None
    seconds: float
    error: str | None = None
    tokens: str | None = None
    expressible: bool = True


@dataclass
class SearchResult:
    families: int | None
    explored: int | None
    unique: int | None
    conflict_seeds: int | None
    deepest: int | None
    stopped: str | None
    sources: list[str]
    seconds: float
    error: str | None = None


@dataclass
class VariantResult:
    name: str
    description: str
    transforms: list[str]
    edit_cost: int
    known_cases: list[CaseResult]
    search: SearchResult
    rejected_known: int
    ambiguous_known: int
    pareto: bool = False


def spelled_statements(spelling: Spelling, statements: list[list[str]]) -> list[str]:
    result: list[str] = []
    for index, statement in enumerate(statements):
        if index and not spelling.stat_terminator:
            result.extend(spelling.stat_separator)
        result.extend(statement)
        result.extend(spelling.stat_terminator)
    return result


def spelled_constructor_decl(spelling: Spelling, body: list[str]) -> list[str]:
    """A `Main() { ... }` constructor declaration; its parens are decl syntax,
    untouched by the call transforms, so they always stay LPAREN/RPAREN."""
    return [
        "UIDENT", "LPAREN", "RPAREN", "LCURLY",
        *body,
        "RCURLY", *spelling.decl_terminator, "EOF",
    ]


def spell_nullable_array_binding(spelling: Spelling) -> list[str] | None:
    return [
        "ALIAS", "UIDENT", "EQUAL", "UIDENT", "QSTNMARK", "UIDENT",
        "LBRACKET", "RBRACKET", "LBRACKET", "RBRACKET",
        *spelling.decl_terminator, "EOF",
    ]


def spell_adjacent_computed_call(spelling: Spelling) -> list[str] | None:
    if spelling.group is None or not spelling.computed_call_statement:
        return None
    group_open, group_close = spelling.group
    named_open, named_close = spelling.named_call
    computed_open, computed_close = spelling.computed_call
    named = ["LIDENT", *named_open, *named_close]
    computed = [*group_open, "LIDENT", *group_close, *computed_open, *computed_close]
    return spelled_constructor_decl(
        spelling, spelled_statements(spelling, [named, computed])
    )


def spell_abort_handler_attachment(spelling: Spelling) -> list[str] | None:
    named_open, named_close = spelling.named_call
    statement = [
        "LIDENT", *named_open,
        "TILDE", "TILDE", "LIDENT", "QSTNQSTN", "LIDENT",
        *named_close,
    ]
    return spelled_constructor_decl(
        spelling, spelled_statements(spelling, [statement])
    )


def spell_named_call_statement(spelling: Spelling) -> list[str] | None:
    named_open, named_close = spelling.named_call
    statement = ["LIDENT", *named_open, "STRING", *named_close]
    return spelled_constructor_decl(
        spelling, spelled_statements(spelling, [statement])
    )


KNOWN_CASES = (
    KnownCase(
        "nullable-array-binding",
        "T ? U[] must bind the array to U, not the nullable result",
        spell_nullable_array_binding,
    ),
    KnownCase(
        "adjacent-computed-call",
        "f() followed by (x)() must not have both one- and two-statement parses",
        spell_adjacent_computed_call,
    ),
    KnownCase(
        "abort-handler-attachment",
        "the abort handler must attach to the outer expression",
        spell_abort_handler_attachment,
    ),
    KnownCase(
        "named-call-statement",
        'an ordinary named call statement such as print("hello") must keep exactly one parse',
        spell_named_call_statement,
    ),
)


PRIMARY_GROUP = '  | "(" e=expr ")" { Nodes.Expr.Parenthized e }\n'

VERB_CALL = '''verb_call:
  | receiver=app part=ioption(meth_part) "(" args=separated_list(COMMA, expr) ")" abort_handle=ioption(abort_handle) %prec LPAREN {
      match part with
      | None -> Nodes.Verb_call.Func { callee = receiver; args; abort_handle }
      | Some (is_mut, name) ->
          Nodes.Verb_call.Meth { this = receiver; callee = name; args; abort_handle; is_mut }
    }
  | name_type=name_type "(" args=separated_list(COMMA, expr) ")" abort_handle=ioption(abort_handle) %prec LPAREN {
      Nodes.Verb_call.Constructor { name_type; args; abort_handle }
    }
'''

STAT_CALL = '''  | verb_call=verb_call {
      Nodes.Stat.VerbCall verb_call
    }
'''


def replace_once(source: str, old: str, new: str, transform: str) -> str:
    count = source.count(old)
    if count != 1:
        raise ValueError(
            f"{transform}: expected one grammar anchor, found {count}: {old[:70]!r}"
        )
    return source.replace(old, new, 1)


def replace_statement_lists(source: str, helper: str, transform: str) -> str:
    source = replace_once(
        source,
        "  | decls=list(decl) EOF",
        "  | decls=decl_sequence EOF",
        transform,
    )
    if "list(stat)" not in source:
        raise ValueError(f"{transform}: no statement-list anchors found")
    source = source.replace("list(stat)", "stat_sequence")
    return replace_once(source, "\nbody:\n", f"\n{helper}\nbody:\n", transform)


def semicolon_separated(source: str) -> str:
    helper = '''decl_sequence:
  | values=separated_list(";", decl) ioption(";") { values }

stat_sequence:
  | values=separated_list(";", stat) ioption(";") { values }
'''
    return replace_statement_lists(source, helper, "semicolon-separated")


def semicolon_terminated(source: str) -> str:
    helper = '''decl_sequence:
  | values=list(terminated(decl, ";")) { values }

stat_sequence:
  | values=list(terminated(stat, ";")) { values }
'''
    return replace_statement_lists(source, helper, "semicolon-terminated")


def newline_separated(source: str) -> str:
    source = replace_once(
        source,
        '%token SEMICOLON   ";"\n',
        '%token SEMICOLON   ";"\n%token NEWLINE     "<newline>"\n',
        "newline-separated",
    )
    helper = '''decl_sequence:
  | { [] }
  | NEWLINE { [] }
  | boption(NEWLINE) first=decl rest=list(preceded(NEWLINE, decl)) boption(NEWLINE) {
      first :: rest
    }

stat_sequence:
  | { [] }
  | NEWLINE { [] }
  | boption(NEWLINE) first=stat rest=list(preceded(NEWLINE, stat)) boption(NEWLINE) {
      first :: rest
    }
'''
    return replace_statement_lists(source, helper, "newline-separated")


def named_statement_calls(source: str) -> str:
    helper = '''statement_verb_call:
  | callee=name_expr "(" args=separated_list(COMMA, expr) ")" abort_handle=ioption(abort_handle) {
      Nodes.Verb_call.Func {
        callee = Nodes.Expr.NameExpr callee;
        args;
        abort_handle;
      }
    }
  | receiver=app is_mut=meth_marker callee=name_expr
    "(" args=separated_list(COMMA, expr) ")" abort_handle=ioption(abort_handle) {
      Nodes.Verb_call.Meth {
        this = receiver;
        callee = Nodes.Expr.NameExpr callee;
        args;
        abort_handle;
        is_mut;
      }
    }
  | name_type=name_type "(" args=separated_list(COMMA, expr) ")" abort_handle=ioption(abort_handle) {
      Nodes.Verb_call.Constructor { name_type; args; abort_handle }
    }

'''
    source = replace_once(source, "\nstat:\n", f"\n{helper}stat:\n", "named-statement-calls")
    return replace_once(
        source,
        STAT_CALL,
        '''  | verb_call=statement_verb_call {
      Nodes.Stat.VerbCall verb_call
    }
''',
        "named-statement-calls",
    )


def bracket_grouping(source: str) -> str:
    return replace_once(
        source,
        PRIMARY_GROUP,
        '  | "[" e=expr "]" { Nodes.Expr.Parenthized e }\n',
        "bracket-grouping",
    )


def brace_grouping(source: str) -> str:
    return replace_once(
        source,
        PRIMARY_GROUP,
        '  | "{" e=expr "}" { Nodes.Expr.Parenthized e }\n',
        "brace-grouping",
    )


def keyword_grouping(source: str) -> str:
    source = replace_once(
        source,
        '%token LPAREN      "("\n',
        '%token GROUP       "group"\n%token LPAREN      "("\n',
        "keyword-grouping",
    )
    return replace_once(
        source,
        PRIMARY_GROUP,
        '  | GROUP "(" e=expr ")" { Nodes.Expr.Parenthized e }\n',
        "keyword-grouping",
    )


def no_grouping(source: str) -> str:
    return replace_once(source, PRIMARY_GROUP, "", "no-grouping")


def transform_all_calls(source: str, kind: str) -> str:
    if kind == "bracket":
        replacement = VERB_CALL.replace(
            '"(" args=separated_list(COMMA, expr) ")"',
            '"[" args=separated_list(COMMA, expr) "]"',
        )
    elif kind in {"marked", "dotted"}:
        marker = '"@"' if kind == "marked" else '"."'
        replacement = VERB_CALL.replace(
            '"(" args=separated_list(COMMA, expr) ")"',
            f'{marker} "(" args=separated_list(COMMA, expr) ")"',
        )
    else:
        raise AssertionError(kind)
    return replace_once(source, VERB_CALL, replacement, f"{kind}-calls")


def bracket_calls(source: str) -> str:
    return transform_all_calls(source, "bracket")


def marked_calls(source: str) -> str:
    return transform_all_calls(source, "marked")


def dotted_calls(source: str) -> str:
    return transform_all_calls(source, "dotted")


def computed_calls(source: str, kind: str) -> str:
    if kind == "marked":
        opening, closing = '"@" "("', '")"'
    elif kind == "bracket":
        opening, closing = '"["', '"]"'
    else:
        raise AssertionError(kind)
    replacement = f'''verb_call:
  | callee=name_expr "(" args=separated_list(COMMA, expr) ")" abort_handle=ioption(abort_handle) {{
      Nodes.Verb_call.Func {{
        callee = Nodes.Expr.NameExpr callee;
        args;
        abort_handle;
      }}
    }}
  | receiver=app {opening} args=separated_list(COMMA, expr) {closing} abort_handle=ioption(abort_handle) {{
      Nodes.Verb_call.Func {{ callee = receiver; args; abort_handle }}
    }}
  | receiver=app part=meth_part "(" args=separated_list(COMMA, expr) ")" abort_handle=ioption(abort_handle) {{
      let (is_mut, name) = part in
      Nodes.Verb_call.Meth {{ this = receiver; callee = name; args; abort_handle; is_mut }}
    }}
  | name_type=name_type "(" args=separated_list(COMMA, expr) ")" abort_handle=ioption(abort_handle) {{
      Nodes.Verb_call.Constructor {{ name_type; args; abort_handle }}
    }}
'''
    return replace_once(source, VERB_CALL, replacement, f"{kind}-computed-calls")


OP_HANDLE_SLOTS = (
    ("comparison_op", "EQEQ"),
    ("additive_op", "PLUS"),
    ("multiplicative_op", "STAR"),
)

HANDLED_EXPR = '''handled_expr:
  | e=expr { e }
  | e=expr abort_handle=abort_handle {
      Nodes.Expr.WithAbortHandle { value = e; abort_handle }
    }

'''


def anchored_abort_handles(source: str) -> str:
    """Abort handlers may only attach at delimited boundaries: statement
    calls, declaration values, return/resolve/abort values, call arguments,
    and grouping parentheses — never inside an undelimited expression."""
    name = "anchored-abort-handles"
    for rule, prec in OP_HANDLE_SLOTS:
        source = replace_once(
            source,
            f"  | left=expr op={rule} right=expr abort_handle=ioption(abort_handle) %prec {prec} {{\n"
            "      Nodes.Expr.VerbCall (Nodes.Verb_call.Op { op; left; right; abort_handle })\n"
            "    }\n",
            f"  | left=expr op={rule} right=expr %prec {prec} {{\n"
            "      Nodes.Expr.VerbCall (Nodes.Verb_call.Op { op; left; right; abort_handle = None })\n"
            "    }\n",
            name,
        )
    source = replace_once(
        source,
        '  | "~" value=expr abort_handle=ioption(abort_handle) %prec TILDE {\n'
        "      Nodes.Expr.VerbCall (Nodes.Verb_call.Flip { value; abort_handle })\n"
        "    }\n",
        '  | "~" value=expr %prec TILDE {\n'
        "      Nodes.Expr.VerbCall (Nodes.Verb_call.Flip { value; abort_handle = None })\n"
        "    }\n",
        name,
    )
    source = replace_once(
        source,
        VERB_CALL,
        '''verb_call:
  | receiver=app part=ioption(meth_part) "(" args=separated_list(COMMA, handled_expr) ")" {
      match part with
      | None -> Nodes.Verb_call.Func { callee = receiver; args; abort_handle = None }
      | Some (is_mut, name) ->
          Nodes.Verb_call.Meth { this = receiver; callee = name; args; abort_handle = None; is_mut }
    }
  | name_type=name_type "(" args=separated_list(COMMA, handled_expr) ")" {
      Nodes.Verb_call.Constructor { name_type; args; abort_handle = None }
    }
''',
        name,
    )
    source = replace_once(
        source,
        STAT_CALL,
        '''  | verb_call=verb_call abort_handle=ioption(abort_handle) {
      Nodes.Stat.VerbCall (Nodes.with_statement_handle verb_call abort_handle)
    }
''',
        name,
    )
    source = replace_once(
        source,
        '  | name=LIDENT type_=type_expr "=" value=expr {\n',
        '  | name=LIDENT type_=type_expr "=" value=handled_expr {\n',
        name,
    )
    source = replace_once(
        source,
        '  | name=LIDENT constructor=name_type "(" args=separated_list(COMMA, expr) ")" {\n',
        '  | name=LIDENT constructor=name_type "(" args=separated_list(COMMA, handled_expr) ")" {\n',
        name,
    )
    for keyword in ("ABORT", "RETURN", "RESOLVE"):
        source = replace_once(
            source,
            f"  | {keyword} value=expr {{\n",
            f"  | {keyword} value=handled_expr {{\n",
            name,
        )
    source = replace_once(
        source,
        PRIMARY_GROUP,
        '  | "(" e=handled_expr ")" { Nodes.Expr.Parenthized e }\n',
        name,
    )
    return replace_once(source, "\nexpr:\n", f"\n{HANDLED_EXPR}expr:\n", name)


def marked_computed_calls(source: str) -> str:
    return computed_calls(source, "marked")


def bracket_computed_calls(source: str) -> str:
    return computed_calls(source, "bracket")


TRANSFORMS: dict[str, Transform] = {
    "semicolon-separated": semicolon_separated,
    "semicolon-terminated": semicolon_terminated,
    "newline-separated": newline_separated,
    "named-statement-calls": named_statement_calls,
    "bracket-grouping": bracket_grouping,
    "brace-grouping": brace_grouping,
    "keyword-grouping": keyword_grouping,
    "no-grouping": no_grouping,
    "bracket-calls": bracket_calls,
    "marked-calls": marked_calls,
    "dotted-calls": dotted_calls,
    "marked-computed-calls": marked_computed_calls,
    "bracket-computed-calls": bracket_computed_calls,
    "anchored-abort-handles": anchored_abort_handles,
}


BRACKET_CALL = (("LBRACKET",), ("RBRACKET",))
MARKED_CALL = (("AT", "LPAREN"), ("RPAREN",))
DOTTED_CALL = (("DOT", "LPAREN"), ("RPAREN",))

SPELLINGS: dict[str, Callable[[Spelling], Spelling]] = {
    "semicolon-separated": lambda s: replace(s, stat_separator=("SEMICOLON",)),
    "semicolon-terminated": lambda s: replace(
        s, stat_terminator=("SEMICOLON",), decl_terminator=("SEMICOLON",)
    ),
    "newline-separated": lambda s: replace(s, stat_separator=("NEWLINE",)),
    "named-statement-calls": lambda s: replace(s, computed_call_statement=False),
    "bracket-grouping": lambda s: replace(s, group=(("LBRACKET",), ("RBRACKET",))),
    "brace-grouping": lambda s: replace(s, group=(("LCURLY",), ("RCURLY",))),
    "keyword-grouping": lambda s: replace(s, group=(("GROUP", "LPAREN"), ("RPAREN",))),
    "no-grouping": lambda s: replace(s, group=None),
    "bracket-calls": lambda s: replace(
        s, named_call=BRACKET_CALL, computed_call=BRACKET_CALL
    ),
    "marked-calls": lambda s: replace(s, named_call=MARKED_CALL, computed_call=MARKED_CALL),
    "dotted-calls": lambda s: replace(s, named_call=DOTTED_CALL, computed_call=DOTTED_CALL),
    "marked-computed-calls": lambda s: replace(s, computed_call=MARKED_CALL),
    "bracket-computed-calls": lambda s: replace(s, computed_call=BRACKET_CALL),
    # The witnesses spell their abort handlers at positions that stay legal
    # (call arguments and declaration values), so the spelling is unchanged.
    "anchored-abort-handles": lambda s: s,
}


def variant_spelling(variant: Variant) -> Spelling:
    spelling = BASELINE_SPELLING
    for name in variant.transforms:
        spelling = SPELLINGS[name](spelling)
    return spelling


def case_tokens(case: KnownCase, variant: Variant) -> str | None:
    tokens = case.spell(variant_spelling(variant))
    return None if tokens is None else " ".join(tokens)


VARIANTS = (
    Variant("baseline", "Current Zane syntax", (), 0),
    Variant(
        "semicolon-separated",
        "Require semicolons between adjacent declarations and statements",
        ("semicolon-separated",),
        1,
    ),
    Variant(
        "semicolon-terminated",
        "Require every declaration and statement to end in a semicolon",
        ("semicolon-terminated",),
        1,
    ),
    Variant(
        "named-statement-calls",
        "Only direct named functions, named methods, and constructors may be call statements",
        ("named-statement-calls",),
        1,
    ),
    Variant(
        "semicolons-and-named-statements",
        "Require separators and restrict call statements to statically named calls",
        ("semicolon-separated", "named-statement-calls"),
        2,
    ),
    Variant(
        "terminated-and-named-statements",
        "Require terminators and restrict call statements to statically named calls",
        ("semicolon-terminated", "named-statement-calls"),
        2,
    ),
    Variant(
        "newline-separated",
        "Make newlines grammatical statement separators",
        ("newline-separated",),
        2,
    ),
    Variant(
        "newline-and-named-statements",
        "Use significant newlines and statically named call statements",
        ("newline-separated", "named-statement-calls"),
        3,
    ),
    Variant("bracket-grouping", "Use [expression] for grouping", ("bracket-grouping",), 1),
    Variant("brace-grouping", "Use {expression} for grouping", ("brace-grouping",), 1),
    Variant(
        "keyword-grouping",
        "Use group(expression) for explicit grouping",
        ("keyword-grouping",),
        1,
    ),
    Variant("no-grouping", "Remove general expression grouping", ("no-grouping",), 1),
    Variant("bracket-calls", "Use receiver[arguments] for every call", ("bracket-calls",), 1),
    Variant("marked-calls", "Use receiver@(arguments) for every call", ("marked-calls",), 1),
    Variant("dotted-calls", "Use receiver.(arguments) for every call", ("dotted-calls",), 1),
    Variant(
        "marked-computed-calls",
        "Keep f(args), but require value@(args) for computed callees",
        ("marked-computed-calls",),
        2,
    ),
    Variant(
        "bracket-computed-calls",
        "Keep f(args), but require value[args] for computed callees",
        ("bracket-computed-calls",),
        2,
    ),
    Variant(
        "semicolons-and-marked-computed-calls",
        "Combine statement separators with marked computed invocation",
        ("semicolon-separated", "marked-computed-calls"),
        3,
    ),
    Variant(
        "named-statements-and-marked-computed-calls",
        "Mark computed invocation and forbid it as a standalone statement",
        ("named-statement-calls", "marked-computed-calls"),
        3,
    ),
    Variant(
        "bracket-grouping-and-semicolons",
        "Combine bracket grouping with statement separators",
        ("bracket-grouping", "semicolon-separated"),
        2,
    ),
    Variant(
        "bracket-grouping-and-named-statements",
        "Combine bracket grouping with named-only call statements",
        ("bracket-grouping", "named-statement-calls"),
        2,
    ),
    Variant(
        "bracket-grouping-semicolons-and-named-statements",
        "Combine bracket grouping, separators, and named-only call statements",
        ("bracket-grouping", "semicolon-separated", "named-statement-calls"),
        3,
    ),
    Variant(
        "keyword-grouping-and-semicolons",
        "Combine keyword grouping with statement separators",
        ("keyword-grouping", "semicolon-separated"),
        2,
    ),
    Variant(
        "keyword-grouping-and-named-statements",
        "Combine keyword grouping with named-only call statements",
        ("keyword-grouping", "named-statement-calls"),
        2,
    ),
    Variant(
        "anchored-abort-handles",
        "Attach abort handlers only at delimited boundaries, not inside expressions",
        ("anchored-abort-handles",),
        2,
    ),
    Variant(
        "anchored-handles-and-semicolons",
        "Combine anchored abort handlers with statement separators",
        ("anchored-abort-handles", "semicolon-separated"),
        3,
    ),
)


# Outside the engine's own exit codes (0 unambiguous, 1 ambiguous), so a killed
# process is reported as a failed case rather than mistaken for a result.
EXIT_TIMED_OUT = 124

DERIVATIONS_RE = re.compile(r"Accepting derivations: (\d+)")
FAMILIES_RE = re.compile(r"Found (\d+) complete ambiguity")
EXPLORED_RE = re.compile(r"Explored (\d+) frontiers \((\d+) unique\); (\d+) conflict seeds")
NO_WITNESS_RE = re.compile(
    r"(?:after exploring|found in) (\d+) (?:explored )?frontiers \((\d+) unique\)"
)
DEPTH_RE = re.compile(r"Search stopped at depth (\d+)")
STOPPED_RE = re.compile(r"Search stopped (?:because|at depth \d+ because) ([^.;]+)")
SOURCE_RE = re.compile(r"^\s*Source: (.*)$", re.MULTILINE)


def apply_variant(source: str, variant: Variant) -> str:
    result = source
    for name in variant.transforms:
        result = TRANSFORMS[name](result)
    header = (
        "(* Generated by tools/syntax_experiment.py.\n"
        f"   Variant: {variant.name}\n"
        f"   Transformations: {', '.join(variant.transforms) or 'none'} *)\n"
    )
    return header + result


def run_process(
    command: list[str], env: dict[str, str] | None = None, timeout: float | None = None
) -> tuple[int, str, str, float]:
    """Run ``command``, returning ``(code, stdout, stderr, seconds)``.

    ``timeout`` is a process-level backstop, not the search's own budget: the
    engine enforces ``--timeout`` itself, but a wedged process would otherwise
    block its worker forever. On expiry the child is killed and the call
    reports a non-zero status rather than raising.
    """
    started = time.monotonic()
    try:
        completed = subprocess.run(
            command, text=True, capture_output=True, env=env, timeout=timeout
        )
    except subprocess.TimeoutExpired as expired:
        def decode(stream: str | bytes | None) -> str:
            if stream is None:
                return ""
            if isinstance(stream, bytes):
                return stream.decode("utf-8", "replace")
            return stream

        return (
            EXIT_TIMED_OUT,
            decode(expired.stdout),
            (
                decode(expired.stderr)
                + f"search did not exit within {expired.timeout:.0f}s and was killed"
            ),
            time.monotonic() - started,
        )
    return completed.returncode, completed.stdout, completed.stderr, time.monotonic() - started


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
        message = (stderr or stdout or f"search exited with status {code}").strip()
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
        command, env=environment, timeout=process_timeout(args)
    )
    if code not in {0, 1}:
        message = (stderr or stdout or f"search exited with status {code}").strip()
        return SearchResult(None, None, None, None, None, None, [], seconds, message)

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
    return SearchResult(
        families,
        explored,
        unique,
        seeds,
        int(depth_match.group(1)) if depth_match else None,
        stopped_match.group(1) if stopped_match else None,
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


def select_variants(names: list[str] | None) -> list[Variant]:
    by_name = {variant.name: variant for variant in VARIANTS}
    if not names:
        return list(VARIANTS)
    unknown = sorted(set(names) - by_name.keys())
    if unknown:
        raise ValueError(f"unknown variants: {', '.join(unknown)}")
    return [by_name[name] for name in names]


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("grammar", nargs="?", type=Path, default=Path("lib/cst/parser.mly"))
    result.add_argument("--variant", action="append", help="variant to run; repeatable")
    result.add_argument("--list", action="store_true", help="list variants and exit")
    result.add_argument("--emit-only", action="store_true", help="only materialize grammars")
    result.add_argument("--emit-dir", type=Path, help="keep generated grammars in this directory")
    result.add_argument(
        "--search-command",
        default="_build/default/tools/ambiguity_search.exe",
        help="command prefix used to invoke the ambiguity search; the default"
        " expects a prior `dune build tools/ambiguity_search.exe`",
    )
    result.add_argument("--max-tokens", type=int)
    result.add_argument("--timeout", type=float)
    result.add_argument("--max-witnesses", type=int)
    result.add_argument("--skip-known", action="store_true")
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
            " run `dune build tools/ambiguity_search.exe` first"
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

        mark_pareto(results)
        results.sort(key=metric)
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
            "results": [asdict(result) for result in results],
        }
        json_path = args.output.with_suffix(".json")
        markdown_path = args.output.with_suffix(".md")
        json_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        markdown_path.write_text(render_markdown(args, results) + "\n", encoding="utf-8")
        print(f"JSON: {json_path}")
        print(f"Markdown: {markdown_path}")
        return 0 if all(result.search.error is None for result in results) else 2
    finally:
        if temporary is not None:
            temporary.cleanup()


if __name__ == "__main__":
    raise SystemExit(main())
