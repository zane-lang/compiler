#!/usr/bin/env python3
"""What an experiment is made of.

A variant is data: a name, a description, and the list of named grammar
transformations it composes. So are the spellings a variant implies for the
source forms it changes, the known ambiguity witnesses every variant is
replayed against, and the records a run produces for each of them.

Nothing here changes a grammar, runs a process, or prints a report. Splitting
the experiments by responsibility rather than one file per variant is what
makes that possible: the variants below are a table, and the modules beside
this one are the code that reads it.
"""

from __future__ import annotations

from dataclasses import dataclass, replace
from typing import Callable

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
