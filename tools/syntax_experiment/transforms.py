#!/usr/bin/env python3
"""The grammar rewrites a variant is composed of.

Each transform takes the grammar's source text and returns it with one syntax
decision spelled differently -- a statement list separated rather than
terminated, calls grouped with brackets rather than parentheses, an abort
handler anchored to its operation. They anchor on the grammar's own text and
refuse to guess: a transform that cannot find its anchor raises rather than
returning the source unchanged, so a grammar that has moved on is reported
instead of silently producing a baseline run.
"""

from __future__ import annotations

from tools.syntax_experiment.model import Transform, Variant

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


def apply_variant(source: str, variant: Variant) -> str:
    result = source
    for name in variant.transforms:
        result = TRANSFORMS[name](result)
    header = (
        "(* Generated by tools/syntax_experiment/cli.py.\n"
        f"   Variant: {variant.name}\n"
        f"   Transformations: {', '.join(variant.transforms) or 'none'} *)\n"
    )
    return header + result
