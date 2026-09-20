#!/usr/bin/env python3
import os
import shutil
import subprocess
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
ENGINE = ROOT / "_build" / "default" / "tools" / "ambiguity" / "ambiguity_search.exe"
PARSER_SHAPE = ROOT / "_build" / "default" / "tools" / "parser" / "parser_shape.exe"
GRAMMAR = ROOT / "lib" / "cst" / "parser.mly"


def engine_environment() -> dict[str, str] | None:
    menhir = os.environ.get("AMBIGUITY_MENHIR") or shutil.which("menhir")
    if not ENGINE.exists() or not PARSER_SHAPE.exists() or menhir is None:
        return None
    return {
        **os.environ,
        "AMBIGUITY_MENHIR": menhir,
        "AMBIGUITY_MEMORY_MB": "64",
        "AMBIGUITY_MAX_FRONTIER_RATIO": "1.0",
        "AMBIGUITY_JOBS": "1",
    }


class ParserGrammarAmbiguityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.environment = engine_environment()
        if self.environment is None:
            self.skipTest(
                "requires built ambiguity_search/parser_shape executables and menhir"
            )

    def check(self, tokens: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(ENGINE), "--check-tokens", tokens, str(GRAMMAR)],
            env=self.environment,
            text=True,
            capture_output=True,
            timeout=120,
        )

    def assert_derivations(self, tokens: str, source: str, expected: int) -> None:
        # How many complete parses the grammar gives this token sequence: 0 is
        # rejected, 1 is accepted and unambiguous, 2 or more is an ambiguity.
        # No tree shape is asserted, so this reaches sequences that are meant
        # to have no tree at all.
        result = self.check(tokens)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        # The whole line, so that a count of 10 cannot satisfy an expected 1.
        reported = [
            line.strip()
            for line in result.stdout.splitlines()
            if line.startswith("Accepting derivations:")
        ]
        self.assertEqual(
            reported,
            [f"Accepting derivations: {expected}"],
            f"{source}\n{result.stdout}",
        )

    def assert_grouping(self, tokens: str, source: str, expected: str) -> None:
        result = self.check(tokens)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Accepting derivations: 1", result.stdout)

        parsed = subprocess.run(
            [str(PARSER_SHAPE), source],
            text=True,
            capture_output=True,
            timeout=30,
        )
        self.assertEqual(parsed.returncode, 0, parsed.stdout + parsed.stderr)
        self.assertEqual(parsed.stdout.strip(), expected)

    def test_shorthand_body_keeps_the_nearest_call(self) -> None:
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "UIDENT QSTNMARK UIDENT LPAREN RPAREN THICK_ARROW "
            "FALSE LPAREN RPAREN SEMICOLON RCURLY EOF",
            "Int length() { abort Int ? Int() => false(); }",
            "lambda(call(bool))",
        )

    def test_parentheses_allow_calling_the_lambda(self) -> None:
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT LPAREN "
            "UIDENT QSTNMARK UIDENT LPAREN RPAREN THICK_ARROW FALSE "
            "RPAREN LPAREN RPAREN SEMICOLON RCURLY EOF",
            "Int length() { abort (Int ? Int() => false)(); }",
            "call(paren(lambda(bool)))",
        )

    def test_shorthand_body_keeps_the_nearest_field_access(self) -> None:
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "UIDENT QSTNMARK UIDENT LPAREN RPAREN THICK_ARROW "
            "FALSE DOT LIDENT SEMICOLON RCURLY EOF",
            "Int length() { abort Int ? Int() => false.length; }",
            "lambda(dot(bool))",
        )

    def test_parentheses_allow_field_access_on_the_lambda(self) -> None:
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT LPAREN "
            "UIDENT QSTNMARK UIDENT LPAREN RPAREN THICK_ARROW FALSE "
            "RPAREN DOT LIDENT SEMICOLON RCURLY EOF",
            "Int length() { abort (Int ? Int() => false).length; }",
            "dot(paren(lambda(bool)))",
        )

    def test_mixed_postfix_chain_stays_in_the_lambda_body(self) -> None:
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "UIDENT QSTNMARK UIDENT LPAREN RPAREN THICK_ARROW "
            "LIDENT LPAREN RPAREN DOT LIDENT SEMICOLON RCURLY EOF",
            "Int length() { abort Int ? Int() => value().field; }",
            "lambda(dot(call(name)))",
        )

    def test_prefix_wraps_the_mixed_postfix_chain(self) -> None:
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "UIDENT QSTNMARK UIDENT LPAREN RPAREN THICK_ARROW "
            "TILDE LIDENT LPAREN RPAREN DOT LIDENT SEMICOLON RCURLY EOF",
            "Int length() { abort Int ? Int() => ~value().field; }",
            "lambda(flip(dot(call(name))))",
        )

    def test_dot_constructor_has_one_constructor_reading(self) -> None:
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "UIDENT DOT LIDENT LPAREN RPAREN SEMICOLON RCURLY EOF",
            "Int length() { abort Vector2.zeros(); }",
            "named_ctor()",
        )

    def test_spawn_takes_the_outer_call(self) -> None:
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "SPAWN FALSE LPAREN RPAREN LPAREN RPAREN SEMICOLON RCURLY EOF",
            "Int length() { abort spawn false()(); }",
            "spawn(call(call(bool)))",
        )

    def test_parentheses_allow_calling_what_a_spawn_produces(self) -> None:
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT LPAREN "
            "SPAWN FALSE LPAREN RPAREN RPAREN LPAREN RPAREN SEMICOLON RCURLY EOF",
            "Int length() { abort (spawn false())(); }",
            "call(paren(spawn(call(bool))))",
        )

    def test_leading_reference_binds_the_lambda_return_type(self) -> None:
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "AMPERSAND UIDENT LPAREN RPAREN THICK_ARROW FALSE SEMICOLON RCURLY EOF",
            "Int length() { abort &Int () => false; }",
            "lambda(bool)",
        )

    def test_parentheses_allow_referencing_the_lambda(self) -> None:
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT AMPERSAND LPAREN "
            "UIDENT LPAREN RPAREN THICK_ARROW FALSE RPAREN SEMICOLON RCURLY EOF",
            "Int length() { abort &(Int () => false); }",
            "ref(paren(lambda(bool)))",
        )

    def test_a_trailing_block_joins_the_outer_call(self) -> None:
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "LIDENT LPAREN FALSE LPAREN RPAREN RPAREN LCURLY RCURLY "
            "RCURLY EOF",
            "Int length() { abort value(false()) { } }",
            "call(name, call(bool), block)",
        )

    def test_both_spellings_of_a_block_argument_are_arguments(self) -> None:
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "LIDENT LPAREN LCURLY ABORT FALSE SEMICOLON RCURLY RPAREN "
            "LCURLY RCURLY RCURLY EOF",
            "Int length() { abort value({ abort false; }) { } }",
            "call(name, block, block)",
        )

    def test_a_trailing_block_reaches_a_method_call(self) -> None:
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "LIDENT LPAREN RPAREN COLON LIDENT LPAREN RPAREN LCURLY RCURLY "
            "RCURLY EOF",
            "Int length() { abort value():length() { } }",
            "meth(call(name), name, block)",
        )

    def test_a_match_keeps_the_brace_that_holds_its_arms(self) -> None:
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "MATCH LPAREN LIDENT LPAREN RPAREN RPAREN LCURLY RCURLY "
            "RCURLY EOF",
            "Int length() { abort match (value()) { } }",
            "match(call(name))",
        )

    def test_a_scrutinee_closes_its_own_block_inside_the_parentheses(
        self,
    ) -> None:
        # The scrutinee's `)` is written after its trailing block, so the block
        # is the call's and the brace that follows holds the arms.
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "MATCH LPAREN LIDENT LPAREN RPAREN LCURLY RCURLY RPAREN "
            "LCURLY RCURLY RCURLY EOF",
            "Int length() { abort match (value() { }) { } }",
            "match(call(name, block))",
        )

    def test_the_scrutinee_parentheses_end_it_before_the_arms_brace(
        self,
    ) -> None:
        # An expression may end in a brace of its own -- a constructor's field
        # body, a map literal, a call's trailing argument -- so a bare scrutinee
        # would leave the following `{` with two owners, and an operator gives
        # each owner enough to finish on. The `)` names the owner before the
        # brace is read, so the bare spelling is not a sentence and each
        # grouping has to be written out.
        self.assert_derivations(
            "LIDENT UIDENT EQUAL MATCH UIDENT LCURLY RCURLY LESSEQ UIDENT "
            "LCURLY RCURLY EOF",
            "x Foo = match A { } <= B { }",
            0,
        )
        self.assert_derivations(
            "LIDENT UIDENT EQUAL MATCH LPAREN UIDENT RPAREN LCURLY RCURLY "
            "LESSEQ UIDENT LCURLY RCURLY EOF",
            "x Foo = match (A) { } <= B { }",
            1,
        )
        self.assert_derivations(
            "LIDENT UIDENT EQUAL MATCH LPAREN UIDENT LCURLY RCURLY LESSEQ "
            "UIDENT RPAREN LCURLY RCURLY EOF",
            "x Foo = match (A { } <= B) { }",
            1,
        )

    def test_a_postfix_call_reaches_the_arms_brace_the_same_way(self) -> None:
        # An operator is not what supplies the second owner: a postfix call on
        # the match itself does as well, since a call may trail a block. The
        # search finds this shape and the operator shape as two families of the
        # bare spelling; the parentheses settle both.
        self.assert_derivations(
            "LIDENT UIDENT EQUAL MATCH UIDENT LCURLY RCURLY LPAREN RPAREN "
            "LCURLY RCURLY EOF",
            "x Foo = match A { } ( ) { }",
            0,
        )
        self.assert_derivations(
            "LIDENT UIDENT EQUAL MATCH LPAREN UIDENT RPAREN LCURLY RCURLY "
            "LPAREN RPAREN LCURLY RCURLY EOF",
            "x Foo = match (A) { } ( ) { }",
            1,
        )
        self.assert_derivations(
            "LIDENT UIDENT EQUAL MATCH LPAREN UIDENT LCURLY RCURLY LPAREN "
            "RPAREN RPAREN LCURLY RCURLY EOF",
            "x Foo = match (A { } ( )) { }",
            1,
        )

    def test_several_scrutinees_share_one_pair_of_parentheses(self) -> None:
        # The parentheses delimit the list; they do not build a value out of it.
        self.assert_derivations(
            "LIDENT UIDENT EQUAL MATCH LPAREN LIDENT COMMA LIDENT RPAREN "
            "LCURLY RCURLY EOF",
            "x Foo = match (left, right) { }",
            1,
        )

    def test_a_brace_argument_is_told_from_a_block_by_its_first_mark(
        self,
    ) -> None:
        # `,` after the first expression opens a map entry's value; `;` ends a
        # statement. The two never compete for the same text.
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "LIDENT LPAREN LCURLY LIDENT COMMA FALSE SEMICOLON RCURLY RPAREN "
            "SEMICOLON RCURLY EOF",
            "Int length() { abort value({ first, false; }); }",
            "call(name, map(name, bool))",
        )
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "LIDENT LPAREN LCURLY ABORT FALSE SEMICOLON RCURLY RPAREN "
            "SEMICOLON RCURLY EOF",
            "Int length() { abort value({ abort false; }); }",
            "call(name, block)",
        )

    def test_a_map_literal_may_trail_a_call(self) -> None:
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "LIDENT LPAREN RPAREN LCURLY LIDENT COMMA FALSE SEMICOLON RCURLY "
            "RCURLY EOF",
            "Int length() { abort value() { first, false; } }",
            "call(name, map(name, bool))",
        )

    def test_a_terminator_separates_two_adjacent_import_readings(self) -> None:
        # The one obligation in docs/ambiguity.md that turned out to be a bug
        # rather than a fork: `import core$ main Unit() { }` had two complete
        # derivations, since both readings are a run of declarations. Each is
        # reachable on its own once the `;` says where the import stops, and
        # the unterminated spelling is no longer a program at all.
        self.assert_derivations(
            "IMPORT LIDENT DOLLAR LIDENT UIDENT LPAREN RPAREN LCURLY RCURLY EOF",
            "import core$ main Unit() { }",
            0,
        )
        self.assert_derivations(
            "IMPORT LIDENT DOLLAR SEMICOLON LIDENT UIDENT LPAREN RPAREN "
            "LCURLY RCURLY EOF",
            "import core$; main Unit() { }",
            1,
        )
        self.assert_derivations(
            "IMPORT LIDENT DOLLAR LIDENT SEMICOLON UIDENT LPAREN RPAREN "
            "LCURLY RCURLY EOF",
            "import core$main; Unit() { }",
            1,
        )
        # The shorthand body reaches the same fork, and a body holds the same
        # two forms as package scope does.
        self.assert_derivations(
            "IMPORT LIDENT DOLLAR LIDENT UIDENT LPAREN RPAREN THICK_ARROW "
            "INT EOF",
            "import core$ main Int() => 1",
            0,
        )
        self.assert_derivations(
            "UIDENT LIDENT LPAREN RPAREN LCURLY IMPORT LIDENT DOLLAR LIDENT "
            "UIDENT LPAREN RPAREN LCURLY RCURLY RCURLY EOF",
            "Unit f() { import core$ main Unit() { } }",
            0,
        )

    def test_a_trailing_block_joins_a_constructor_call(self) -> None:
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "UIDENT LPAREN LIDENT RPAREN LCURLY RCURLY RCURLY EOF",
            "Int length() { abort Vector2(first) { } }",
            "ctor(name, block)",
        )

    def test_a_trailing_block_reaches_a_named_constructor(self) -> None:
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "UIDENT DOT LIDENT LPAREN LIDENT RPAREN LCURLY RCURLY RCURLY EOF",
            "Int length() { abort Vector2.fromPair(first) { } }",
            "named_ctor(name, block)",
        )

    def test_a_map_literal_may_trail_a_constructor_call(self) -> None:
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "UIDENT LPAREN LIDENT RPAREN LCURLY LIDENT COMMA FALSE SEMICOLON "
            "RCURLY RCURLY EOF",
            "Int length() { abort Vector2(first) { second, false; } }",
            "ctor(name, map(name, bool))",
        )

    def test_an_empty_argument_list_keeps_the_lambda_reading(self) -> None:
        # `Foo() { ... }` is a lambda literal whose return type is `Foo`
        # (syntax.md §3.8), and in statement position a constructor
        # declaration as well. A nullary constructor call may not trail,
        # because it would be spelled exactly that way; the block goes inside
        # the argument list instead. See docs/spec-divergences.md §3.
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "UIDENT LPAREN RPAREN LCURLY RCURLY RCURLY EOF",
            "Int length() { abort Vector2() { } }",
            "lambda(block)",
        )
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "UIDENT LPAREN LCURLY RCURLY RPAREN SEMICOLON RCURLY EOF",
            "Int length() { abort Vector2({ }); }",
            "ctor(block)",
        )

    def test_a_constructor_scrutinee_closes_itself_the_same_way(
        self,
    ) -> None:
        # A constructor call reaches the trailing form through its own
        # production, and the scrutinee parentheses close it just as they close
        # a function call's.
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "MATCH LPAREN UIDENT LPAREN LIDENT RPAREN LCURLY RCURLY RPAREN "
            "LCURLY RCURLY RCURLY EOF",
            "Int length() { abort match (Vector2(first) { }) { } }",
            "match(ctor(name, block))",
        )
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "MATCH LPAREN UIDENT LPAREN LIDENT RPAREN RPAREN LCURLY RCURLY "
            "RCURLY EOF",
            "Int length() { abort match (Vector2(first)) { } }",
            "match(ctor(name))",
        )

    def test_nothing_continues_a_constructor_call_past_its_trailing_block(
        self,
    ) -> None:
        # The `}` ends the statement, so neither a `;` nor a further call may
        # follow it, and a field-constructor call has no `)` to elide and so
        # never trails at all.
        self.assert_derivations(
            "UIDENT LIDENT LPAREN RPAREN LCURLY UIDENT LPAREN LIDENT RPAREN "
            "LCURLY RCURLY SEMICOLON RCURLY EOF",
            "Unit f() { Vector2(first) { }; }",
            0,
        )
        self.assert_derivations(
            "UIDENT LIDENT LPAREN RPAREN LCURLY UIDENT LPAREN LIDENT RPAREN "
            "LCURLY RCURLY LPAREN RPAREN SEMICOLON RCURLY EOF",
            "Unit f() { Vector2(first) { } (); }",
            0,
        )
        self.assert_derivations(
            "UIDENT LIDENT LPAREN RPAREN LCURLY UIDENT LCURLY LIDENT EQUAL "
            "LIDENT SEMICOLON RCURLY LCURLY RCURLY RCURLY EOF",
            "Unit f() { Vector2{ x = first; } { } }",
            0,
        )

    def test_the_instantiation_shorthand_takes_a_trailing_block(self) -> None:
        # `name VarType(args, ...)` is a constructor call with a name in front
        # of it, so it trails on the same terms. The empty list is the lambda
        # variable's, for the same reason the bare call's is the lambda
        # literal's.
        self.assert_derivations(
            "UIDENT LIDENT LPAREN RPAREN LCURLY LIDENT UIDENT LPAREN LIDENT "
            "RPAREN LCURLY RCURLY RCURLY EOF",
            "Unit f() { v Vector2(first) { } }",
            1,
        )
        self.assert_derivations(
            "UIDENT LIDENT LPAREN RPAREN LCURLY LIDENT UIDENT LPAREN RPAREN "
            "LCURLY RCURLY RCURLY EOF",
            "Unit f() { v Vector2() { } }",
            1,
        )

    def test_bare_type_member_has_one_value_reading(self) -> None:
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "UIDENT DOT LIDENT SEMICOLON RCURLY EOF",
            "Int length() { abort Colors.red; }",
            "type_member",
        )

    def test_a_type_passed_as_a_value_is_not_a_postfix_base(self) -> None:
        # A type may be written where a value is expected (generics.md §5.3),
        # and the production sits at expression level rather than among the
        # postfix bases. That is what keeps the three uppercase forms below at
        # one reading each: written as a `primary` the type name would reach
        # `.`, `(` and `[` through `app`, and each of them would gain a second
        # derivation as an access, a call, or a subscript on a type value.
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "LIDENT LPAREN UIDENT RPAREN SEMICOLON RCURLY EOF",
            "Int length() { abort register(Int); }",
            "call(name, type_value)",
        )
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "UIDENT LPAREN LIDENT RPAREN SEMICOLON RCURLY EOF",
            "Int length() { abort Int(seed); }",
            "ctor(name)",
        )
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT "
            "UIDENT DOT LIDENT DOT LIDENT SEMICOLON RCURLY EOF",
            "Int length() { abort Operator.add.identity; }",
            "dot(type_member)",
        )

    def test_only_a_bare_name_may_be_passed_as_a_type(self) -> None:
        # An applied generic type, a guest type, and a verb type all have a
        # spelling that a following bracket continues, so admitting them here
        # would fork on the token after the name rather than on the name
        # itself. See docs/spec-divergences.md.
        self.assert_derivations(
            "UIDENT LIDENT LPAREN RPAREN LCURLY LIDENT UIDENT LPAREN UIDENT "
            "COMMA INT RPAREN SEMICOLON RCURLY EOF",
            "Unit f() { arr Array(Int, 10000); }",
            1,
        )
        self.assert_derivations(
            "UIDENT LIDENT LPAREN RPAREN LCURLY LIDENT LPAREN UIDENT LESS "
            "UIDENT COMMA INT MORE RPAREN SEMICOLON RCURLY EOF",
            "Unit f() { register(Array<Int, 4>); }",
            0,
        )
        self.assert_derivations(
            "UIDENT LIDENT LPAREN RPAREN LCURLY LIDENT LPAREN AMPERSAND "
            "UIDENT RPAREN SEMICOLON RCURLY EOF",
            "Unit f() { register(&Int); }",
            0,
        )
        self.assert_derivations(
            "UIDENT LIDENT LPAREN RPAREN LCURLY LIDENT LPAREN UIDENT "
            "LBRACKET INT RBRACKET RPAREN SEMICOLON RCURLY EOF",
            "Unit f() { register(Int[3]); }",
            0,
        )

    def test_a_loose_operator_groups_below_every_unprefixed_one(self) -> None:
        # operators.md §3.1. The loose tier changes nothing but the nesting,
        # so the nesting is the whole assertion: `'*` is level 6 and every
        # unprefixed operator is levels 1-5, so both comparisons close before
        # it joins them.
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT LIDENT MORE LIDENT "
            "LOOSE_STAR LIDENT MORE LIDENT SEMICOLON RCURLY EOF",
            "Int length() { abort a > b '* c > d; }",
            "mul(more(name, name), more(name, name))",
        )
        # The same operator unprefixed, for contrast: `*` is level 3, so it
        # binds inside the comparison instead and `>` groups left.
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT LIDENT MORE LIDENT "
            "STAR LIDENT MORE LIDENT SEMICOLON RCURLY EOF",
            "Int length() { abort a > b * c > d; }",
            "more(more(name, mul(name, name)), name)",
        )

    def test_the_loose_tier_mirrors_the_order_it_came_from(self) -> None:
        # §3.1's own second example: levels 6-8 keep the relative order of
        # levels 3-5, so `'*` binds tighter than `'+` exactly as `*` does
        # than `+`.
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT LIDENT EQEQ LIDENT "
            "LOOSE_STAR LIDENT EQEQ LIDENT LOOSE_PLUS LIDENT EQEQ LIDENT "
            "SEMICOLON RCURLY EOF",
            "Int length() { abort a == b '* c == d '+ e == f; }",
            "add(mul(eq(name, name), eq(name, name)), eq(name, name))",
        )
        # And the loose comparisons are looser still, being level 8.
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT LIDENT LOOSE_STAR "
            "LIDENT LOOSE_LESS LIDENT LOOSE_STAR LIDENT SEMICOLON RCURLY EOF",
            "Int length() { abort a '* b '< c '* d; }",
            "less(mul(name, name), mul(name, name))",
        )

    def test_a_loose_operator_is_looser_than_its_own_unprefixed_form(
        self,
    ) -> None:
        # The mirror is one tier deep and sits entirely below the unprefixed
        # levels, so the two spellings of one operator are not equals: `+` at
        # level 4 closes before `'*` at level 6 takes it.
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT LIDENT LOOSE_STAR "
            "LIDENT PLUS LIDENT SEMICOLON RCURLY EOF",
            "Int length() { abort a '* b + c; }",
            "mul(name, add(name, name))",
        )
        self.assert_grouping(
            "UIDENT LIDENT LPAREN RPAREN LCURLY ABORT LIDENT STAR LIDENT "
            "LOOSE_STAR LIDENT SEMICOLON RCURLY EOF",
            "Int length() { abort a * b '* c; }",
            "mul(mul(name, name), name)",
        )



if __name__ == "__main__":
    unittest.main()
