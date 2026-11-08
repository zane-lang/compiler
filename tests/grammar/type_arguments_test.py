"""Types are standalone constructor arguments, never ordinary operands."""

import subprocess
import unittest

from tests.ambiguity.engine_support import ENGINE, ROOT, engine_environment


class ConstructorTypeArgumentTests(unittest.TestCase):
    def test_constructor_arguments_do_not_reintroduce_type_operands(self) -> None:
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
             "UIDENT LCURLY LIDENT EQUAL UIDENT SEMICOLON RCURLY", 1),
            ("x Result = Ctor(Int) {}",
             "UIDENT LPAREN UIDENT RPAREN LCURLY RCURLY", 1),
            ("x Result = Ctor(Int + 1);", "UIDENT LPAREN UIDENT PLUS INT RPAREN SEMICOLON", 0),
            ("x Result = func(Int);", "LIDENT LPAREN UIDENT RPAREN SEMICOLON", 0),
            ("x Result = Int;", "UIDENT SEMICOLON", 0),
            ("x Result = (Int);", "LPAREN UIDENT RPAREN SEMICOLON", 0),
            ("x Result = [Int];", "LBRACKET UIDENT RBRACKET SEMICOLON", 0),
            ("x Result = 1 + Int;", "INT PLUS UIDENT SEMICOLON", 0),
            ("x Result = Ctor(func(Int));",
             "UIDENT LPAREN LIDENT LPAREN UIDENT RPAREN RPAREN SEMICOLON", 0),
            ("x Result = Ctor(Int(1) + 2);",
             "UIDENT LPAREN UIDENT LPAREN INT RPAREN PLUS INT RPAREN SEMICOLON", 1),
            ("x Result = [1](2) {}",
             "LBRACKET INT RBRACKET LPAREN INT RPAREN LCURLY RCURLY", 1),
            # An applied type and a reference to a named type are type values
            # too. Each is a prefix of a lambda (`Foo<1>[]() {}`, `&Foo() {}`),
            # and neither may be an operand, so each witness keeps one reading.
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
            ("x Result = Ctor{kind = Array<Int, 4>;}",
             "UIDENT LCURLY LIDENT EQUAL UIDENT LESS UIDENT COMMA INT MORE SEMICOLON RCURLY", 1),
            ("x Result = Ctor{kind = &Port;}",
             "UIDENT LCURLY LIDENT EQUAL AMPERSAND UIDENT SEMICOLON RCURLY", 1),
            # Still not operands, and still constructor-only.
            ("x Result = Ctor(Foo<1> + 2);",
             "UIDENT LPAREN UIDENT LESS INT MORE PLUS INT RPAREN SEMICOLON", 0),
            ("x Result = Ctor(Foo<1>[]);",
             "UIDENT LPAREN UIDENT LESS INT MORE LBRACKET RBRACKET RPAREN SEMICOLON", 0),
            ("x Result = Ctor(Int[Int]);",
             "UIDENT LPAREN UIDENT LBRACKET UIDENT RBRACKET RPAREN SEMICOLON", 0),
            ("x Result = Ctor(^Foo);", "UIDENT LPAREN CARET UIDENT RPAREN SEMICOLON", 0),
            ("x Result = Ctor(&&Foo);", "UIDENT LPAREN AMPERSAND AMPERSAND UIDENT RPAREN SEMICOLON", 0),
            ("x Result = func(Foo<Int>);",
             "LIDENT LPAREN UIDENT LESS UIDENT MORE RPAREN SEMICOLON", 0),
            ("x Result = func(&Foo);", "LIDENT LPAREN AMPERSAND UIDENT RPAREN SEMICOLON", 0),
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
