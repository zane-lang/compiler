#!/usr/bin/env python3
import subprocess
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
PARSER_ACCEPT = ROOT / "_build" / "default" / "tools" / "parser" / "parser_accept.exe"


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
        # An operand continues the statement past the brace just as a postfix
        # would, so the binary forms are closed off too.
        self.assert_rejects("Unit use() { total Int = run() { g(); } + Int(1); }")
        self.assert_rejects("Unit use() { ok Bool = run() { g(); } '* other; }")
        self.assert_rejects("Unit use() { ok Bool = run() { g(); } == other; }")
        # Parentheses close the call before the operator sees it, which is how
        # such a value is continued.
        self.assert_parses(
            "Unit use() { total Int = (run() { g(); }) + Int(1); }"
        )
        # The binary form can sit anywhere inside the statement, so the whole
        # of its expression is searched -- not just the outermost operand.
        self.assert_rejects(
            "Unit use() { f Int() => run() { g(); } + Int(1); }"
        )
        self.assert_rejects(
            "Unit use() { f Int(this Node) mut => run() { g(); } + Int(1); }"
        )
        self.assert_rejects(
            "Unit use() { total Int = match (c) { red => run() { g(); } + Int(1); } }"
        )
        self.assert_rejects(
            "Unit use() { wrap(run() { g(); } + Int(1)); }"
        )
        self.assert_rejects(
            "Unit use() { total Int = parse(s) ?? run() { g(); } + Int(1); }"
        )
        # Including inside the parentheses that are otherwise the escape.
        self.assert_rejects(
            "Unit use() { total Int = (run() { g(); } + Int(1)); }"
        )
        self.assert_parses(
            'Unit use() { done Unit = run({ work(); }) ? e { resolve Unit(); } }'
        )
        # A statement closed by its own brace takes no terminator, which says
        # nothing about what is written inside it: a continuation in the
        # closing call's own argument, or in a constructor field's default, is
        # the same mistake and is rejected the same way.
        self.assert_rejects(
            "Unit use() { run(wrap() { g(); } + Int(1)) { h(); } }"
        )
        self.assert_rejects(
            "Unit use() { Foo{ a Int = wrap() { g(); } + Int(1); } { h(); } }"
        )

    def test_a_statement_ends_where_its_terminator_says(self) -> None:
        # A statement is closed by a `;` or by a `}`, and the grammar decides
        # which (lexical.md §6.3). The terminator used to be optional there,
        # with the mismatch checked after the parse -- and then after
        # `abort false` a `[` could either continue the expression or open the
        # next statement, since `[` and `(` are the two tokens a statement can
        # begin with. Both readings reached the end of the input, and with two
        # finished parses the parser stopped before `Statement_check` had a tree
        # to read. The 2026-09-21 proof run found it.
        self.assert_rejects("Int {} { abort false[]() }")
        self.assert_parses("Int {} { abort false[](); }")
        # Not special to `abort`: any statement whose expression ends `[](...)`.
        self.assert_parses("Unit f() { return false[](); }")
        self.assert_parses("Unit f() { x Int = false[](); }")
        self.assert_parses("Unit f() { a = false[](); }")

    def test_a_statement_closed_by_a_brace_is_closed_by_the_grammar(self) -> None:
        # Every form that can end on a `}` has to reach it without a `;`: the
        # grammar no longer takes the terminator as optional, so a form it did
        # not list as brace-closing would now be a parse error.
        self.assert_parses("Unit f() { abort a + match (x) { } }")
        self.assert_parses("Unit f() { x Foo = Foo{a = b;} }")
        self.assert_parses("Unit f() { x Foo{a = b;} }")
        self.assert_parses("Unit f() { Foo{a = b;} }")
        self.assert_parses("Unit f() { f Int() => match (x) { } }")
        self.assert_parses("Unit f() { f() ? e { } }")
        self.assert_parses("Unit f() { f() ?? match (x) { } }")
        # And a statement that does not end in one is refused by the grammar
        # itself, rather than parsed and checked afterwards.
        self.assert_rejects("Unit f() { abort false }")
        self.assert_rejects("Unit f() { x Int = y }")

    def test_a_value_closed_by_a_brace_takes_no_postfix(self) -> None:
        # The `}` of a match, a map literal, an `init` or a constructor call by
        # fields may end its statement (lexical.md §6.3), so what follows it is
        # the next statement rather than a call, subscript or member on it --
        # the rule a trailing argument already follows.
        self.assert_parses("Unit f() { abort match (x) { } (y)(); }")
        self.assert_parses("Unit f() { abort { k, v; } [y](); }")
        self.assert_parses("Unit f() { abort Foo{a = b;} (y)(); }")
        self.assert_rejects("Unit f() { abort match (x) { } (y); }")
        self.assert_rejects("Unit f() { x Int = { k, v; }[k]; }")
        self.assert_rejects("Unit f() { x Int = Foo{a = b;}.a; }")
        self.assert_rejects("Unit f() { x Int = Foo{a = b;}:size(); }")
        self.assert_rejects("Unit f() { use(match (x) { } (y)); }")
        # Parentheses close the value first, which is how it is continued.
        self.assert_parses("Unit f() { abort (match (x) { })(y); }")
        self.assert_parses("Unit f() { x Int = ({ k, v; })[k]; }")
        self.assert_parses("Unit f() { x Int = (Foo{a = b;}).a; }")
        self.assert_parses("Unit f() { x Int = (Foo{a = b;}):size(); }")
        self.assert_parses("Unit f() { use((match (x) { })(y)); }")
        # As an argument or an operand the value itself is unchanged.
        self.assert_parses("Unit f() { use(match (x) { }, &{ k, v; }); }")
        self.assert_parses("Unit f() { x Int = Foo{a = b;} ?? y; }")

    def test_a_constructor_call_trails_its_last_argument(self) -> None:
        # Spec syntax.md §4.9 says this of calls in general, and a constructor
        # call is one. The empty argument list is the exception; it has its own
        # test below.
        self.assert_parses(
            '''
            Unit use(name String) {
                worker Thread(name) {
                    poll();
                }
                pool Pool.sized(4) {
                    poll();
                }
                queued Queue(name, { warm(); }) {
                    drain();
                }
                labels Table(name) {
                    "x", Float(3);
                }
                started Thread = Thread(name) {
                    poll();
                }
                Thread(name) {
                    poll();
                }
                return Unit();
            }
            '''
        )
        # The same call written in full, which ends on the `)` and so carries
        # the terminator.
        self.assert_parses("Unit use(n String) { worker Thread(n, { poll(); }); }")
        # The brace ends the statement, so nothing may follow it -- the same
        # rule a function call's trailing block is under.
        self.assert_rejects("Unit use(n String) { worker Thread(n) { poll(); }; }")
        self.assert_rejects("Unit use(n String) { Thread(n) { poll(); }; }")
        self.assert_rejects("Unit use(n String) { Thread(n) { poll(); } () }")
        self.assert_rejects(
            "Unit use(n String) { Thread(n) { poll(); } ? e { resolve Unit(); } }"
        )
        self.assert_rejects(
            "Unit use(n String) { total Int = Thread(n) { poll(); } + Int(1); }"
        )
        # A field-constructor call closes on the `}` of its own field body, so
        # it has no `)` to elide and never trails.
        self.assert_rejects("Unit use(n String) { Thread{ name = n; } { poll(); } }")

    def test_an_empty_argument_list_stays_with_the_lambda_literal(self) -> None:
        # `Foo() { ... }` is a lambda literal whose return type is `Foo`
        # (syntax.md §3.8), and in statement position a constructor
        # declaration with a block body (§3.3). A nullary constructor call may
        # not trail, because it would be spelled exactly that way; the block
        # goes inside the argument list. See docs/spec-divergences.md §3.
        self.assert_parses(
            '''
            Unit use() {
                make Thread() {
                    return Thread("worker");
                }
                started Thread = Thread({ poll(); });
                Thread({ poll(); });
                return Unit();
            }
            '''
        )
        # Read as a lambda literal, it is a declaration, so the brace ends it
        # and a `;` after it marks nothing.
        self.assert_rejects("Unit use() { make Thread() { return t; }; }")

    def test_a_statement_ending_in_a_brace_takes_no_terminator(self) -> None:
        self.assert_parses(
            '''
            Unit use(c Color) {
                picked String = match (c) {
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
                total = match (loudest) {
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
            "Unit use() { total = match (loudest) { note => total; }; }"
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
            package demo;
            import std;

            type Meters = Int
            alias Metres = Meters

            Int double(value Int) => value * Int(2)
            answer Int = Int(42)
            '''
        )
        self.assert_rejects("Int double(value Int) => value * Int(2);")
        self.assert_rejects("answer Int = Int(42);")

    def test_package_and_import_are_the_two_that_are_terminated(self) -> None:
        # They end on a bare name -- `import pkg$` ends just before one -- so
        # nothing about their own shape says where they stop, and the `;` is
        # what says it instead.
        self.assert_parses("package demo;")
        self.assert_rejects("package demo")
        self.assert_parses("import std;")
        self.assert_rejects("import std")

    def test_a_terminator_tells_a_whole_package_import_from_a_member_one(
        self,
    ) -> None:
        # Without the `;` this is two programs at once: a whole-package import
        # followed by a lambda-valued declaration, and a member import of
        # `main` followed by a constructor declaration for `Unit`. Both halves
        # are complete declarations, so nothing downstream can pick.
        self.assert_rejects(
            '''
            import core$
            main Unit() { }
            '''
        )
        self.assert_parses(
            '''
            import core$;
            main Unit() { }
            '''
        )
        self.assert_parses(
            '''
            import core$main;
            Unit() { }
            '''
        )

    def test_the_header_terminator_is_required_in_a_body_too(self) -> None:
        # A body holds the same two forms on the same terms, so the rule has to
        # hold at both levels to close the ambiguity at either. Both
        # alternatives of `header_decl` reach the body, so both are checked at
        # that boundary.
        self.assert_parses("Unit use() { import core$; return Unit(); }")
        self.assert_rejects("Unit use() { import core$ return Unit(); }")
        self.assert_parses("Unit use() { package demo; return Unit(); }")
        self.assert_rejects("Unit use() { package demo return Unit(); }")

    def test_every_import_form(self) -> None:
        self.assert_parses(
            '''
            import math;
            import math as m;
            import math$sqrt;
            import math$Vector;
            import math$sqrt as root;
            import math$Vector as Vec;
            import math$[sqrt, pow];
            import math$[sqrt, Vector];
            import math$;
            '''
        )

    def test_an_import_ends_where_its_terminator_ends_it(self) -> None:
        # `import pkg$` takes everything past the separator, and the `;` is
        # what leaves the following name nowhere to go but the next
        # declaration.
        self.assert_parses(
            '''
            import math$;
            answer Int = Int(4)

            import text$;
            Int double(v Int) => v * Int(2)

            import shapes$;
            type Meters = Int
            '''
        )

    def test_an_alias_names_one_thing_and_keeps_its_casing(self) -> None:
        # A list has no single name to rename, and `pkg$` qualifies nothing.
        self.assert_rejects("import math$[sqrt, pow] as m;")
        self.assert_rejects("import math$ as m;")
        # A whole-package alias is a package name, so it is lowercase-initial.
        self.assert_rejects("import math as M;")
        # A member alias may not cross the casing classes.
        self.assert_rejects("import math$sqrt as Root;")
        self.assert_rejects("import math$Vector as vec;")

    def test_an_import_list_is_an_ordinary_flat_list(self) -> None:
        self.assert_rejects("import math$[];")
        self.assert_rejects("import math$[sqrt, pow,];")
        # Operators resolve by operand home package and are not importable.
        self.assert_rejects("import math$+;")

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

    def test_match_enum_map_type_members_and_inequality(self) -> None:
        self.assert_parses(
            '''
            package demo;
            import std;

            type Color = enum [ red, green ]
            Color.label String {
                red = "Red";
                green = "Green";
            }

            String show(c Color) => match (c) {
                red => Color.red.label;
                green => "Green";
            }

            Unit use() {
                different Bool = true ~= false;
                label String = show(Color.red);
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
                label String = match (c) {
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

    def test_only_a_brace_mould_closes_a_declaration_in_a_body(self) -> None:
        # Which delimiter a mould uses is decided by its contents, and only a
        # brace ends a statement: the peer mould is a `[ ]` list, so inside a
        # body it is terminated like any other statement that does not end in
        # a brace. At package scope neither takes a terminator.
        self.assert_parses(
            '''
            Unit use() {
                type Braced = struct { x Int; }
                type Cased = variant { some Int; }
                type Marked = #struct { next &Marked; }
                type Listed = enum [ red, green ];
                alias Aliased = enum [ up, down ];
                type Meters = Int;
                return Unit();
            }
            '''
        )
        self.assert_rejects("Unit use() { type Listed = enum [ red, green ] }")
        self.assert_rejects("Unit use() { alias Aliased = enum [ up, down ] }")
        self.assert_rejects("Unit use() { type Braced = struct { x Int; }; }")

    def test_comparison_chains_and_the_operators_that_join_them(self) -> None:
        # `Bool` draws from the same operator set as every other type
        # (operators.md §2.4): `*` is conjunction, `+` is disjunction. Joining
        # two comparisons is what the loose tier of §3.1 is for.
        self.assert_parses(
            '''
            Unit use() {
                chained Bool = a < b < c;
                equality Bool = a == b == c;
                both Bool = a < b '* c < d;
                either Bool = a '* b '+ c;
                associative Bool = a '* b '* c;
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

    def test_a_type_is_passed_as_an_ordinary_argument(self) -> None:
        # generics.md §5.3: a type or number reaches a verb either inferred
        # from the value arguments, or passed directly as a value parameter of
        # concept type `Type`. The second half needs a type to be writable
        # where a value is expected, which is what the `Int` arguments below
        # are.
        self.assert_parses(
            '''
            type Vector<T Type> = struct {
                x T;
                y T;
            }

            Vector<T>(T Type) => init{ x = T(0); y = T(0); }

            Array<T, n>(T Type, n Number) => init{ }

            Unit use() {
                vec Vector(Int);
                arr Array(Int, 10000);
                register(Float);
                registry!add(math$Vector);
                machine Slot = @primitives$I64;
                return Unit();
            }
            '''
        )
        # A named constructor takes one on the same terms.
        self.assert_parses("Unit use() { v Vector2.zeros(Int); }")
        # The inferred half is unchanged and still the one a literal drives.
        self.assert_parses(
            "Unit use() { vec Vector(Int(2), Int(3)); }"
        )

    def test_only_a_bare_name_is_a_type_value(self) -> None:
        # A type name written as a value closes on the name. Every other type
        # spelling continues into a bracket that means something else in an
        # expression -- `<` a comparison, `[` a subscript, `&` a reference --
        # so only the bare name may be written here.
        # See docs/spec-divergences.md.
        self.assert_rejects("Unit use() { register(Array<Int, 4>); }")
        self.assert_rejects("Unit use() { register(&Int); }")
        self.assert_rejects("Unit use() { register(Int[3]); }")
        # `Type` is a concept: legal in a parameter position, never as storage.
        self.assert_rejects("Unit use() { held Type = Int; }")
        self.assert_rejects("Type pick() { return Int; }")

    def test_a_quote_selects_the_loose_form_of_a_binary_operator(self) -> None:
        # operators.md §3.1. The two examples the spec itself writes.
        self.assert_parses(
            "Unit use() { ready Bool = age > Int(18) '* hasId; }"
        )
        self.assert_parses(
            "Unit use() { band Bool = a == b '* c == d '+ e == f; }"
        )
        # Every binary operator of §2 has one, and no other token does.
        for loose in ["'*", "'/", "'+", "'-", "'<", "'>", "'<=", "'>=",
                      "'==", "'~="]:
            self.assert_parses(f"Unit use() {{ x Bool = a + b {loose} c + d; }}")

    def test_the_loose_tier_is_one_deep_and_binary_only(self) -> None:
        # Each of these is illegal in operators.md §3.1, and each is spelled
        # with a token the lexer does not have: there is no `''`, no `'~` and
        # no `'|`, so none of them reaches the grammar at all.
        self.assert_rejects("Unit use() { x Bool = a ''* b; }")
        self.assert_rejects("Unit use() { x Bool = '~a; }")
        self.assert_rejects("Unit use() { x Bool = a '| f(); }")
        # The `'` must touch its operator: the loose form is one token.
        self.assert_rejects("Unit use() { x Bool = a ' * b; }")

    def test_there_is_no_pipe(self) -> None:
        # `|` is not a token, so a pipe stops at the lexer whatever its
        # operands; the callable is called instead.
        self.assert_rejects("Unit use() { label String = show|Color.red; }")
        self.assert_rejects("Unit use() { r String = Color.red:render|label; }")
        self.assert_parses("Unit use() { label String = show(Color.red); }")

    def test_a_loose_operator_declares_nothing(self) -> None:
        # §3.1: the loose forms "add no token to the operator vocabulary" of
        # §5.1, so an operator declaration names the unprefixed form only.
        self.assert_parses(
            "Pair<T> *(a Pair<T Type>, b Pair<T>) => Pair(a.left, a.right)"
        )
        self.assert_rejects(
            "Pair<T> '*(a Pair<T Type>, b Pair<T>) => Pair(a.left, a.right)"
        )
        self.assert_rejects("Bool '==(a Pair<T Type>, b Pair<T>) => true")

    def test_a_quote_between_digits_is_still_a_separator(self) -> None:
        # The separator wants digits on both sides, so it never collides with
        # a loose operator, whichever side of the literal one sits on.
        self.assert_parses("Unit use() { n Int = 1'000'000 '* Int(2); }")
        self.assert_parses("Unit use() { n Int = Int(2) '* 1'000'000; }")
        # With no space, the literal ends where the digits do.
        self.assert_parses("Unit use() { n Int = 2'*3; }")


    def test_and_and_or_are_ordinary_names(self) -> None:
        # operators.md §2.4 gives `Bool` the same operator set as every other
        # type, with no `and` or `or` in it. They are no longer keywords, so
        # they carry no meaning of their own in an expression...
        self.assert_rejects("Unit use() { ok Bool = a and b; }")
        self.assert_rejects("Unit use() { ok Bool = a or b; }")
        # ...and, being unreserved, they are available as names again.
        self.assert_parses(
            """
            Unit use() {
                and Bool = true;
                or Bool = false;
                both Bool = and '* or;
                return Unit();
            }
            """
        )

    def test_only_a_primitive_operator_may_be_declared(self) -> None:
        # operators.md 2.1 lists the implementable operators; 2.3 gives the
        # other five as fixed desugarings into that set and says they are
        # "not independently implementable".
        for source in (
            "Int +(a Int, b Int) => a",
            "Int *(a Int, b Int) => a",
            "Int /(a Int, b Int) => a",
            "Bool ==(a Int, b Int) => Bool(true)",
            "Bool <(a Int, b Int) => Bool(true)",
            # The one unary operator, with a production of its own.
            "Int ~(a Int) => a",
        ):
            with self.subTest(source=source):
                self.assert_parses(source)

        # A derived operator is rejected at its declaration. Accepting one
        # would be worse than it looks: every use of `>` is rewritten into a
        # `<` before any call is resolved (docs/desugaring.md 2.3), so the
        # declaration would parse, check, and never be called.
        for source in (
            "Int -(a Int, b Int) => a",
            "Bool ~=(a Int, b Int) => Bool(true)",
            "Bool >(a Int, b Int) => Bool(true)",
            "Bool <=(a Int, b Int) => Bool(true)",
            "Bool >=(a Int, b Int) => Bool(true)",
        ):
            with self.subTest(source=source):
                self.assert_rejects(source)

        # Only the declaration is restricted. Every one of them is still an
        # ordinary operator at a use site.
        self.assert_parses(
            """
            Unit use() {
                a Int = x - y;
                b Bool = x ~= y;
                c Bool = x > y;
                d Bool = x <= y;
                e Bool = x >= y;
                return Unit();
            }
            """
        )


if __name__ == "__main__":
    unittest.main()
