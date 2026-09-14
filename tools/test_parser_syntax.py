#!/usr/bin/env python3
import subprocess
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
PARSER_ACCEPT = ROOT / "_build" / "default" / "tools" / "parser_accept.exe"


class ParserSyntaxTests(unittest.TestCase):
    def setUp(self) -> None:
        if not PARSER_ACCEPT.exists():
            self.skipTest("requires built parser_accept executable")

    def run_parser(self, source: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(PARSER_ACCEPT), source],
            text=True,
            capture_output=True,
            timeout=30,
        )

    def assert_parses(self, source: str) -> None:
        parsed = self.run_parser(source)
        self.assertEqual(parsed.returncode, 0, parsed.stdout + parsed.stderr)

    def assert_rejects(self, source: str) -> None:
        parsed = self.run_parser(source)
        self.assertNotEqual(parsed.returncode, 0, parsed.stdout + parsed.stderr)

    def test_named_field_and_implicit_constructors(self) -> None:
        self.assert_parses(
            '''
            type Vector2 = struct { x Float; y Float; }

            Vector2.zeros() => init{x = Float(0); y = Float(0);}
            Vector2.fromPair{x Float; y Float = Float(0);} => init{x; y;}
            Vector2<T>{x T Type; y T;} => init{x; y;}
            implicit Vector2(v Float) => init{x = v; y = v;}

            Unit use() {
                a Vector2.zeros();
                b Vector2{x = Float(1); y = Float(2);}
                c Vector2.fromPair{x = Float(3);}
                return Unit();
            }
            '''
        )

    def test_a_body_entry_keeps_its_terminator(self) -> None:
        # An entry of a `{ }` body carries its `;` unconditionally, including
        # one whose value ends in a `}`. Only statements take the brace
        # exception.
        self.assert_parses(
            '''
            type Handler = struct { fire Unit[]; }

            Handler.idle() => init{ fire = Unit() { return Unit(); }; }
            '''
        )
        self.assert_rejects(
            "Handler.idle() => init{ fire = Unit() { return Unit(); } }"
        )

    def test_guest_types_subscripts_assignment_and_spawn(self) -> None:
        self.assert_parses(
            '''
            type Node = #struct { next &Node; }

            (this Node)[index Int] => this

            Unit work(this Node) mut {
                this.next = &this;
                guard(true);
                spawn run();
                return Unit();
            }
            '''
        )

    def test_control_flow_is_calls_carrying_block_arguments(self) -> None:
        self.assert_parses(
            '''
            Unit walk(values IntList) {
                index Int = Int(1);
                index!to(values:size()) {
                    guard(values[index] < Int(0));
                    std$print(values[index]);
                }

                ran Bool = if(values:size() == Int(0)) {
                    std$print("empty");
                }
                ran!elif({ resolve values:size() < Int(4); }) {
                    std$print("short");
                }
                ran:else() {
                    std$print("long");
                }

                twice({ std$print("a"); }, { std$print("b"); });
                return Unit();
            }
            '''
        )

    def test_a_trailing_block_closes_a_call_statement(self) -> None:
        self.assert_rejects("Unit use() { run() { std$print(\"once\"); }; }")
        self.assert_rejects("Unit use() { run() { } { } }")
        # Nothing may continue the call past the brace that closed it.
        self.assert_rejects("Unit use() { run() { } () }")
        self.assert_rejects("Unit use() { run() { } [index] }")
        # A handler is one of the things that cannot follow it; the same call
        # with its block inside the argument list takes one.
        self.assert_rejects("Unit use() { run() { } ? e { resolve Unit(); } }")
        self.assert_parses(
            'Unit use() { done Unit = run({ work(); }) ? e { resolve Unit(); } }'
        )

    def test_a_statement_ending_in_a_brace_takes_no_terminator(self) -> None:
        self.assert_parses(
            '''
            Unit use(c Color) {
                picked String = match c {
                    red => "Red";
                    green => "Green";
                }
                ran Bool = if(true) {
                    std$print(picked);
                }
                handled Int = parse("4") ? e {
                    resolve Int(0);
                }
                plain Int = Int(3);
                return Unit();
            }
            '''
        )
        self.assert_rejects("Unit use() { ran Bool = if(true) { g(); }; }")
        self.assert_rejects("Unit use() { plain Int = Int(3) }")
        self.assert_rejects("Unit use() { return Unit() }")

    def test_the_brace_rule_reaches_every_statement_form(self) -> None:
        # Not just declarations and calls: an assignment and a lambda
        # declaration end on their own brace too, and the `=> expr` spelling of
        # the same declaration does not.
        self.assert_parses(
            '''
            Unit use(loudest Severity) {
                total = match loudest {
                    note => total;
                }
                clamp Float(value Float) {
                    return value;
                }
                double Float(value Float) => value * Float(2);
                total = other;
                return Unit();
            }
            '''
        )
        self.assert_rejects(
            "Unit use() { total = match loudest { note => total; }; }"
        )
        self.assert_rejects(
            "Unit use() { clamp Float(value Float) { return value; }; }"
        )
        self.assert_rejects("Unit use() { double Float(v Float) => v }")
        self.assert_rejects("Unit use() { total = other }")

    def test_a_brace_may_not_open_a_statement(self) -> None:
        self.assert_rejects("Unit use() { { std$print(\"scoped\"); } }")
        # The same work is a call taking a block argument.
        self.assert_parses("Unit use() { do() { std$print(\"scoped\"); } }")

    def test_package_scope_declarations_take_no_terminator(self) -> None:
        self.assert_parses(
            '''
            package demo
            import std

            type Meters = Int
            alias Metres = Meters

            Int double(value Int) => value * Int(2)
            answer Int = Int(42)
            '''
        )
        self.assert_rejects("package demo;")
        self.assert_rejects("Int double(value Int) => value * Int(2);")
        self.assert_rejects("answer Int = Int(42);")

    def test_every_import_form(self) -> None:
        self.assert_parses(
            '''
            import math
            import math as m
            import math$sqrt
            import math$Vector
            import math$sqrt as root
            import math$Vector as Vec
            import math$[sqrt, pow]
            import math$[sqrt, Vector]
            import math$
            '''
        )

    def test_an_import_ends_where_its_form_ends(self) -> None:
        # `import pkg$` takes everything past the separator, so the name after
        # it opens the next declaration rather than continuing the import.
        self.assert_parses(
            '''
            import math$
            answer Int = Int(4)

            import text$
            Int double(v Int) => v * Int(2)

            import shapes$
            type Meters = Int
            '''
        )

    def test_an_alias_names_one_thing_and_keeps_its_casing(self) -> None:
        # A list has no single name to rename, and `pkg$` qualifies nothing.
        self.assert_rejects("import math$[sqrt, pow] as m")
        self.assert_rejects("import math$ as m")
        # A whole-package alias is a package name, so it is lowercase-initial.
        self.assert_rejects("import math as M")
        # A member alias may not cross the casing classes.
        self.assert_rejects("import math$sqrt as Root")
        self.assert_rejects("import math$Vector as vec")

    def test_an_import_list_is_an_ordinary_flat_list(self) -> None:
        self.assert_rejects("import math$[]")
        self.assert_rejects("import math$[sqrt, pow,]")
        # Operators resolve by operand home package and are not importable.
        self.assert_rejects("import math$+")

    def test_map_literals(self) -> None:
        self.assert_parses(
            '''
            Unit use() {
                scores Map<String, Int> = {
                    String("first"), Int(1);
                    String("second"), Int(2);
                }
                register({ String("a"), Int(1); });
                register() {
                    String("b"), Int(2);
                }
                return Unit();
            }
            '''
        )
        # A literal is never empty, so a bare `{}` is a block argument.
        self.assert_parses("Unit use() { register({}); }")
        # An entry is exactly a key and a value.
        self.assert_rejects("Unit use() { m Map = { String(\"a\"); }; }")

    def test_match_enum_map_type_members_pipe_and_inequality(self) -> None:
        self.assert_parses(
            '''
            package demo
            import std

            type Color = enum [ red, green ]
            Color.label String {
                red = "Red";
                green = "Green";
            }

            String show(c Color) => match c {
                red => Color.red.label;
                green => "Green";
            }

            Unit use() {
                different Bool = true ~= false;
                label String = show|Color.red;
                rendered String = Color.red:render|label;
                first String = label[0];
                return Unit();
            }
            '''
        )

    def test_an_enum_map_keeps_a_verb_typed_property(self) -> None:
        self.assert_parses(
            '''
            type Color = enum [ red, green ]

            Color.render String[Int] {
                red = renderRed;
                green = renderGreen;
            }
            '''
        )

    def test_match_arm_terminator_follows_the_body_shape(self) -> None:
        self.assert_parses(
            '''
            type Color = enum [ red, green ]

            String show(c Color) {
                label String = match c {
                    red {
                        return "Red";
                    }
                    green => "Green";
                }
                return label;
            }
            '''
        )

    def test_a_mould_closes_its_declaration_and_a_raw_type_does_not(self) -> None:
        self.assert_parses(
            '''
            type Shaped = struct { x Int; }
            type Marked = #struct { next &Marked; }
            type Cased = variant { some Int; }
            type Listed = enum [ red, green ]

            type Meters = Int
            type Mapper<T Type> = T
            alias Metres = Meters
            '''
        )

    def test_comparison_chains_and_short_circuit_keywords(self) -> None:
        self.assert_parses(
            '''
            Unit use() {
                chained Bool = a < b < c;
                equality Bool = a == b == c;
                both Bool = a < b and c < d;
                either Bool = a and b or c;
                associative Bool = a and b and c;
                return Unit();
            }
            '''
        )

    def test_alias_moulds_and_line_comments(self) -> None:
        self.assert_parses(
            '''
            // aliases may use the same mould RHS as type declarations
            alias Pair = struct { left Int; right Int; }
            /// documentation comments are accepted lexically
            type Wrapped = struct { pair Pair; }
            '''
        )

    def test_generic_parameter_introduction_and_collection_literals(self) -> None:
        self.assert_parses(
            '''
            type Buffer<T Type, n Number> = struct {
                data Array<T, n>;
            }

            T first(values Array<T Type, n Number>) => values[0]

            Unit literals() {
                values Array<Int, 3> = Array([Int(1), Int(2), Int(3)]);
                return Unit();
            }
            '''
        )


if __name__ == "__main__":
    unittest.main()
