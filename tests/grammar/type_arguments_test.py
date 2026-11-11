"""Types are whole call arguments, never ordinary operands."""

import subprocess
import unittest

from tests.ambiguity.engine_support import ENGINE, ROOT, engine_environment


class CallTypeArgumentTests(unittest.TestCase):
    def test_call_arguments_do_not_reintroduce_type_operands(self) -> None:
        environment = engine_environment()
        if environment is None:
            self.skipTest("requires the ambiguity engine and Menhir")
        cases = (
            ("x Result = Foo<1>[]() {}",
             "UIDENT LESS INT MORE LBRACKET RBRACKET LPAREN RPAREN LCURLY RCURLY", 1),
            ("x Result = Foo<1>[][Int]() {}",
             "UIDENT LESS INT MORE LBRACKET RBRACKET LBRACKET UIDENT RBRACKET LPAREN RPAREN LCURLY RCURLY", 1),
            ("x Result = Ctor(Foo<1>[]() {});",
             "UIDENT LPAREN UIDENT LESS INT MORE LBRACKET RBRACKET LPAREN RPAREN LCURLY RCURLY RPAREN SEMICOLON", 1),
            ("x Result = Ctor(Int);", "UIDENT LPAREN UIDENT RPAREN SEMICOLON", 1),
            ("x Result = Ctor(pkg$Int);", "UIDENT LPAREN LIDENT DOLLAR UIDENT RPAREN SEMICOLON", 1),
            ("x Result = Ctor{type = Int;}",
             "UIDENT LCURLY LIDENT EQUAL UIDENT SEMICOLON RCURLY", 0),
            ("x Result = Ctor(Int) {}",
             "UIDENT LPAREN UIDENT RPAREN LCURLY RCURLY", 1),
            ("x Result = Ctor(Int + 1);", "UIDENT LPAREN UIDENT PLUS INT RPAREN SEMICOLON", 0),
            ("x Result = Int;", "UIDENT SEMICOLON", 0),
            ("x Result = (Int);", "LPAREN UIDENT RPAREN SEMICOLON", 0),
            ("x Result = [Int];", "LBRACKET UIDENT RBRACKET SEMICOLON", 0),
            ("x Result = 1 + Int;", "INT PLUS UIDENT SEMICOLON", 0),
            ("x Result = Ctor(Int(1) + 2);",
             "UIDENT LPAREN UIDENT LPAREN INT RPAREN PLUS INT RPAREN SEMICOLON", 1),
            ("x Result = [1](2) {}",
             "LBRACKET INT RBRACKET LPAREN INT RPAREN LCURLY RCURLY", 1),
            # Every type is a type value, and none is an operand. Each is a
            # prefix of a lambda (`Foo<1>[]() {}`, `&Foo() {}`, `Int[Int]() {}`),
            # and the token after it decides, so each witness keeps one reading.
            ("x Result = Ctor(Foo<1>);",
             "UIDENT LPAREN UIDENT LESS INT MORE RPAREN SEMICOLON", 1),
            ("x Result = Ctor(Foo<1>, 2);",
             "UIDENT LPAREN UIDENT LESS INT MORE COMMA INT RPAREN SEMICOLON", 1),
            ("x Result = Ctor(Array<Pair<T>, n>);",
             "UIDENT LPAREN UIDENT LESS UIDENT LESS UIDENT MORE COMMA LIDENT MORE RPAREN SEMICOLON", 1),
            ("x Result = Ctor(Foo<1>) {}",
             "UIDENT LPAREN UIDENT LESS INT MORE RPAREN LCURLY RCURLY", 1),
            ("x Result = Ctor(&Foo);", "UIDENT LPAREN AMPERSAND UIDENT RPAREN SEMICOLON", 1),
            ("x Result = Ctor(&Foo<Int>, 2);",
             "UIDENT LPAREN AMPERSAND UIDENT LESS UIDENT MORE COMMA INT RPAREN SEMICOLON", 1),
            ("x Result = Ctor(&Foo() {});",
             "UIDENT LPAREN AMPERSAND UIDENT LPAREN RPAREN LCURLY RCURLY RPAREN SEMICOLON", 1),
            ("x Result = Ctor(&Foo<1>[]() {});",
             "UIDENT LPAREN AMPERSAND UIDENT LESS INT MORE LBRACKET RBRACKET LPAREN RPAREN LCURLY RCURLY RPAREN SEMICOLON", 1),
            ("x Result = Ctor(Foo<1>[]);",
             "UIDENT LPAREN UIDENT LESS INT MORE LBRACKET RBRACKET RPAREN SEMICOLON", 1),
            ("x Result = Ctor(Foo<1>[][Int]);",
             "UIDENT LPAREN UIDENT LESS INT MORE LBRACKET RBRACKET LBRACKET UIDENT RBRACKET RPAREN SEMICOLON", 1),
            ("x Result = Ctor(Foo<1>[][Int]() {});",
             "UIDENT LPAREN UIDENT LESS INT MORE LBRACKET RBRACKET LBRACKET UIDENT RBRACKET LPAREN RPAREN LCURLY RCURLY RPAREN SEMICOLON", 1),
            ("x Result = Ctor(Int[Int]);",
             "UIDENT LPAREN UIDENT LBRACKET UIDENT RBRACKET RPAREN SEMICOLON", 1),
            ("x Result = Ctor(Int[Int], 2);",
             "UIDENT LPAREN UIDENT LBRACKET UIDENT RBRACKET COMMA INT RPAREN SEMICOLON", 1),
            ("x Result = Ctor(Int[Int]) {}",
             "UIDENT LPAREN UIDENT LBRACKET UIDENT RBRACKET RPAREN LCURLY RCURLY", 1),
            ("x Result = Ctor(Int[Int]() {});",
             "UIDENT LPAREN UIDENT LBRACKET UIDENT RBRACKET LPAREN RPAREN LCURLY RCURLY RPAREN SEMICOLON", 1),
            ("x Result = Ctor(Int[this Foo, Int] mut);",
             "UIDENT LPAREN UIDENT LBRACKET THIS UIDENT COMMA UIDENT RBRACKET MUT RPAREN SEMICOLON", 1),
            ("x Result = Ctor(Int?Err[Int]);",
             "UIDENT LPAREN UIDENT QSTNMARK UIDENT LBRACKET UIDENT RBRACKET RPAREN SEMICOLON", 1),
            ("x Result = Ctor(Int?Err[Int]() {});",
             "UIDENT LPAREN UIDENT QSTNMARK UIDENT LBRACKET UIDENT RBRACKET LPAREN RPAREN LCURLY RCURLY RPAREN SEMICOLON", 1),
            ("x Result = Ctor(&Int[Int]);",
             "UIDENT LPAREN AMPERSAND UIDENT LBRACKET UIDENT RBRACKET RPAREN SEMICOLON", 1),
            # A function and a method take a type on the same terms, so a
            # lambda that begins with one still has one reading there too.
            ("x Result = func(Int);", "LIDENT LPAREN UIDENT RPAREN SEMICOLON", 1),
            ("x Result = Ctor(func(Int));",
             "UIDENT LPAREN LIDENT LPAREN UIDENT RPAREN RPAREN SEMICOLON", 1),
            ("x Result = func(Int[Int]);",
             "LIDENT LPAREN UIDENT LBRACKET UIDENT RBRACKET RPAREN SEMICOLON", 1),
            ("x Result = func(Foo<Int>);",
             "LIDENT LPAREN UIDENT LESS UIDENT MORE RPAREN SEMICOLON", 1),
            ("x Result = func(&Foo);", "LIDENT LPAREN AMPERSAND UIDENT RPAREN SEMICOLON", 1),
            ("x Result = func(Foo<1>, 2);",
             "LIDENT LPAREN UIDENT LESS INT MORE COMMA INT RPAREN SEMICOLON", 1),
            ("x Result = func(Int) {}",
             "LIDENT LPAREN UIDENT RPAREN LCURLY RCURLY", 1),
            ("x Result = func(Foo<1>[]() {});",
             "LIDENT LPAREN UIDENT LESS INT MORE LBRACKET RBRACKET LPAREN RPAREN LCURLY RCURLY RPAREN SEMICOLON", 1),
            ("x Result = func(Int[Int]() {});",
             "LIDENT LPAREN UIDENT LBRACKET UIDENT RBRACKET LPAREN RPAREN LCURLY RCURLY RPAREN SEMICOLON", 1),
            ("x Result = func(&Foo() {});",
             "LIDENT LPAREN AMPERSAND UIDENT LPAREN RPAREN LCURLY RCURLY RPAREN SEMICOLON", 1),
            ("x Result = obj!add(Foo<Int>);",
             "LIDENT EXCL LIDENT LPAREN UIDENT LESS UIDENT MORE RPAREN SEMICOLON", 1),
            ("x Result = obj:count(Int[Int]);",
             "LIDENT COLON LIDENT LPAREN UIDENT LBRACKET UIDENT RBRACKET RPAREN SEMICOLON", 1),
            ("x Result = obj!add(Foo<1>[]() {});",
             "LIDENT EXCL LIDENT LPAREN UIDENT LESS INT MORE LBRACKET RBRACKET LPAREN RPAREN LCURLY RCURLY RPAREN SEMICOLON", 1),
            # A roaming owner parses as any type does; the checker rejects it.
            ("x Result = Ctor(^Foo);", "UIDENT LPAREN CARET UIDENT RPAREN SEMICOLON", 1),
            # Never by name: a field constructor's entries are the type's
            # fields, and a type is not stored.
            ("x Result = Ctor{kind = Array<Int, 4>;}",
             "UIDENT LCURLY LIDENT EQUAL UIDENT LESS UIDENT COMMA INT MORE SEMICOLON RCURLY", 0),
            ("x Result = Ctor{kind = &Port;}",
             "UIDENT LCURLY LIDENT EQUAL AMPERSAND UIDENT SEMICOLON RCURLY", 0),
            ("x Result = Ctor{kind = Int[Int];}",
             "UIDENT LCURLY LIDENT EQUAL UIDENT LBRACKET UIDENT RBRACKET SEMICOLON RCURLY", 0),
            # Still not operands, in any call.
            ("x Result = Ctor(Foo<1> + 2);",
             "UIDENT LPAREN UIDENT LESS INT MORE PLUS INT RPAREN SEMICOLON", 0),
            ("x Result = Ctor(Int[Int] + 1);",
             "UIDENT LPAREN UIDENT LBRACKET UIDENT RBRACKET PLUS INT RPAREN SEMICOLON", 0),
            ("x Result = Ctor(Int?Err);", "UIDENT LPAREN UIDENT QSTNMARK UIDENT RPAREN SEMICOLON", 0),
            ("x Result = func(Foo<1> + 2);",
             "LIDENT LPAREN UIDENT LESS INT MORE PLUS INT RPAREN SEMICOLON", 0),
            ("x Result = obj!add(Int[Int] + 1);",
             "LIDENT EXCL LIDENT LPAREN UIDENT LBRACKET UIDENT RBRACKET PLUS INT RPAREN SEMICOLON", 0),
            ("x Result = Ctor(&&Foo);", "UIDENT LPAREN AMPERSAND AMPERSAND UIDENT RPAREN SEMICOLON", 0),
            ("x Result = func(&Foo + 1);", "LIDENT LPAREN AMPERSAND UIDENT PLUS INT RPAREN SEMICOLON", 0),
            ("x Result = Foo<Int>;", "UIDENT LESS UIDENT MORE SEMICOLON", 0),
        )
        for source, value, expected in cases:
            with self.subTest(source=source):
                result = subprocess.run(
                    [str(ENGINE), "--check-tokens",
                     f"LIDENT UIDENT EQUAL {value} EOF",
                     str(ROOT / "lib/cst/parser.mly")],
                    env=environment, text=True, capture_output=True, timeout=120,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout.strip(), f"Accepting derivations: {expected}")
