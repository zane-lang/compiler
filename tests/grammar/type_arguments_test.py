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
            ("x Result = Ctor(Foo<1>[]() {})",
             "UIDENT LPAREN UIDENT LESS INT MORE LBRACKET RBRACKET LPAREN RPAREN LCURLY RCURLY RPAREN", 1),
            ("x Result = Ctor(Int)", "UIDENT LPAREN UIDENT RPAREN", 1),
            ("x Result = Ctor(pkg$Int)", "UIDENT LPAREN LIDENT DOLLAR UIDENT RPAREN", 1),
            ("x Result = Ctor{type = Int;}",
             "UIDENT LCURLY LIDENT EQUAL UIDENT SEMICOLON RCURLY", 1),
            ("x Result = Ctor(Int) {}",
             "UIDENT LPAREN UIDENT RPAREN LCURLY RCURLY", 1),
            ("x Result = Ctor(Int + 1)", "UIDENT LPAREN UIDENT PLUS INT RPAREN", 0),
            ("x Result = func(Int)", "LIDENT LPAREN UIDENT RPAREN", 0),
            ("x Result = Int", "UIDENT", 0),
            ("x Result = (Int)", "LPAREN UIDENT RPAREN", 0),
            ("x Result = [Int]", "LBRACKET UIDENT RBRACKET", 0),
            ("x Result = 1 + Int", "INT PLUS UIDENT", 0),
            ("x Result = Ctor(func(Int))",
             "UIDENT LPAREN LIDENT LPAREN UIDENT RPAREN RPAREN", 0),
            ("x Result = Ctor(Int(1) + 2)",
             "UIDENT LPAREN UIDENT LPAREN INT RPAREN PLUS INT RPAREN", 1),
            ("x Result = [1](2) {}",
             "LBRACKET INT RBRACKET LPAREN INT RPAREN LCURLY RCURLY", 1),
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
