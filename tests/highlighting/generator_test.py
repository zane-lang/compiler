"""Generator contracts: source changes propagate and invalid inputs fail closed."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from tools.grammar import lexical, menhir, treesitter
from tools.grammar.__main__ import ROOT, load, main, outputs


class LexicalTests(unittest.TestCase):
    def setUp(self):
        self.spec, self.overlay = load(ROOT / 'grammar')

    def test_keyword_change_reaches_compiler_and_both_highlighters(self):
        token = next(t for t in self.spec['tokens'] if t['name'] == 'RETURN')
        token['literal'] = 'giveback'
        compiler = menhir.generate((ROOT / 'grammar/syntax.mly').read_text(), self.spec)
        self.assertIn('%token RETURN "giveback"', compiler)
        self.assertIn('"giveback" -> RETURN', lexical.lexer(self.spec))
        self.assertIn('giveback', lexical.sublime(self.spec))
        grammar, query = treesitter.generate(self.spec, 'main', {'main': [menhir.Production(('RETURN', 'EOF'))]}, {}, {})
        self.assertIn('"giveback"', grammar)
        self.assertIn('"giveback" @keyword', query)

    def test_punctuation_spelling_is_not_duplicated_in_productions(self):
        token = next(t for t in self.spec['tokens'] if t['name'] == 'PLUS')
        token['literal'] = '++'
        generated = menhir.generate((ROOT / 'grammar/syntax.mly').read_text(), self.spec)
        self.assertIn('%token PLUS "++"', generated)
        self.assertIn('PLUS {', generated)

    def test_lexical_expression_reaches_all_lexers(self):
        self.spec['expressions']['digit'] = {'range': ['0', '7']}
        self.assertIn("'0'..'7'", lexical.lexer(self.spec))
        self.assertIn('0-7', lexical.sublime(self.spec))
        grammar, _ = treesitter.generate(self.spec, 'main', {'main': [menhir.Production(('INT', 'EOF'))]}, {}, {})
        self.assertIn('0-7', grammar)

    def test_regex_classes_use_named_escapes_for_control_characters(self):
        # A backslash before a raw newline is not portable across the editors'
        # regex dialects; named escapes are, and leave `\` out of the class.
        self.assertEqual(lexical.render({'not': ['\n', '\r']}, {}, 'regex'), r'[^\n\r]')
        self.assertEqual(lexical.render({'not': ['"', '\\']}, {}, 'regex'), r'[^"\\]')
        self.assertEqual(lexical.render({'range': ['\x00', '\t']}, {}, 'regex'), r'[\x00-\t]')
        self.assertEqual(lexical.render(' -', {}, 'regex'), r' \-')

    def test_recursive_and_unknown_lexical_rules_are_rejected(self):
        for definitions in ({'x': {'ref': 'x'}}, {'x': {'ref': 'missing'}}):
            with self.assertRaises(ValueError):
                lexical.render({'ref': 'x'}, definitions, 'regex')

    def test_token_declarations_cannot_be_duplicated_in_template(self):
        with self.assertRaises(ValueError):
            menhir.generate('%token A\n(* @generated-tokens *)', self.spec)

    def test_terminal_spellings_cannot_be_duplicated_in_productions(self):
        with self.assertRaises(ValueError):
            menhir.generate('(* @generated-tokens *)\n%%\nmain: "+" { () }', self.spec)
        menhir.generate('(* @generated-tokens *)\n%%\n(* "+" (* nested *) *)\nmain: PLUS { ignore "{"; ignore \'}\'; () }', self.spec)

    def test_unknown_conflicts_are_rejected(self):
        with self.assertRaises(ValueError):
            treesitter.generate(self.spec, 'main', {'main': [menhir.Production(('INT',))]}, {}, {}, [['missing']])

    def test_nullable_helpers_never_emit_empty_nonstart_rules(self):
        rules = {'main': [menhir.Production(('items', 'EOF'))], 'items': [menhir.Production(()), menhir.Production(('INT', 'items'))]}
        grammar, _ = treesitter.generate(self.spec, 'main', rules, {}, {})
        self.assertIn('_items: $ => seq($.integer_literal, optional($._items))', grammar)
        self.assertNotIn('_items: $ => choice(seq()', grammar)


@unittest.skipUnless(shutil.which(os.environ.get('MENHIR', 'menhir')), 'requires Menhir')
class GenerationTests(unittest.TestCase):
    def test_committed_outputs_are_current(self):
        self.assertEqual(main(['--check']), 0)

    def test_menhir_production_edit_reaches_both_parsers(self):
        with tempfile.TemporaryDirectory(dir=ROOT) as temp:
            source = Path(temp) / 'grammar'
            shutil.copytree(ROOT / 'grammar', source)
            p = source / 'syntax.mly'
            p.write_text(p.read_text().replace('decls=list(top_decl) EOF', 'RETURN decls=list(top_decl) EOF', 1))
            changed = outputs(source, os.environ.get('MENHIR', 'menhir'))
            baseline = outputs(ROOT / 'grammar', os.environ.get('MENHIR', 'menhir'))
            self.assertNotEqual(changed['lib/cst/parser.mly'], baseline['lib/cst/parser.mly'])
            self.assertNotEqual(changed['editors/tree-sitter-zane/grammar.js'], baseline['editors/tree-sitter-zane/grammar.js'])

    def test_failed_generation_does_not_overwrite_outputs(self):
        with tempfile.TemporaryDirectory(dir=ROOT) as temp:
            destination = Path(temp) / 'output'
            sentinel = destination / 'lib/cst/parser.mly'
            sentinel.parent.mkdir(parents=True)
            sentinel.write_text('keep me')
            for flag in ('--menhir', '--tree-sitter'):
                with self.subTest(flag=flag):
                    self.assertEqual(main([flag, '/does/not/exist', '--output-root', str(destination)]), 1)
                    self.assertEqual(sentinel.read_text(), 'keep me')
