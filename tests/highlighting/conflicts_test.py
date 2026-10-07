"""Conflict discovery exercises the real CLI and failure handling."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from tools.grammar import conflicts, source
from tools.grammar.__main__ import ROOT, load, outputs


class CodaTests(unittest.TestCase):
    def test_schema_types_do_not_coerce_literal_spellings(self):
        spec, overlay = load(ROOT / 'grammar')
        literals = {t['name']: t.get('literal') for t in spec['tokens']}
        self.assertEqual(literals['TRUE'], 'true')
        self.assertEqual(literals['FALSE'], 'false')
        self.assertEqual(spec['expressions']['digit'], {'range': ['0', '9']})
        self.assertIs(spec['tokens'][-1]['eof'], True)
        self.assertIsInstance(spec['version'], int)
        self.assertNotIn('conflicts', overlay)

    def test_coda_comments_tables_and_parse_errors(self):
        with tempfile.TemporaryDirectory(dir=ROOT) as temp:
            path = Path(temp) / 'example.coda'
            path.write_text('# Comment\ntokens [\nname literal\nTRUE true\nINT 0\n]\n')
            self.assertEqual(source.read(path), {'tokens': [{'name': 'TRUE', 'literal': 'true'}, {'name': 'INT', 'literal': '0'}]})
            for text in ('version 1\nversion 2\n', 'x "\\u0041"\n', 'x [\na b\nonlyone\n]\n'):
                path.write_text(text)
                with self.subTest(text=text), self.assertRaises(ValueError):
                    source.read(path)

    def test_invalid_typed_fields_are_rejected(self):
        for text in ('yes', '1', 'TRUE'):
            with self.assertRaises(ValueError):
                source.boolean(text, 'any')
        for text in ('1.0', '-1', 'one'):
            with self.assertRaises(ValueError):
                source.integer(text, 'version')

    def test_authored_conflicts_are_rejected(self):
        with tempfile.TemporaryDirectory(dir=ROOT) as temp:
            directory = Path(temp)
            shutil.copy(ROOT / 'grammar/lexicon.coda', directory)
            (directory / 'tree-sitter.coda').write_text('version 1\nconflicts [\n]\n')
            with self.assertRaisesRegex(ValueError, 'discovered automatically'):
                source.load(directory)


class DiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.cli = conflicts.executable()

    @staticmethod
    def render(groups):
        declarations = '[' + ','.join('[' + ','.join('$.' + n for n in group) + ']' for group in groups) + ']'
        # An unambiguous grammar with a local shift/reduce conflict on 'y'.
        # Lookahead 'z' versus 'w' eventually determines the correct branch.
        return '''module.exports = grammar({
          name: "example", conflicts: $ => ''' + declarations + ''', rules: {
            source_file: $ => choice(seq($.a, "y", "z"), seq($.b, "z")),
            a: $ => "x", b: $ => seq("x", "y", "w"),
          }
        });'''

    def run_discovery(self, **kwargs):
        with tempfile.TemporaryDirectory(dir=ROOT) as temp:
            return conflicts.discover(self.render, {'grammars': [{'name': 'example', 'path': '.'}], 'metadata': {'version': '0.1.0'}}, temp, self.cli, **kwargs)

    def test_new_conflict_is_discovered_without_any_authored_list(self):
        grammar, report = self.run_discovery()
        self.assertEqual([c['rules'] for c in report['conflicts']], [['a', 'b']])
        self.assertIn('[$.a,$.b]', grammar)
        self.assertEqual(report['abi'], 15)
        self.assertEqual(report['conflicts'][0]['lookahead'], "'y'")
        self.assertEqual(self.run_discovery(), (grammar, report))

    def test_non_conflict_errors_do_not_get_silently_accepted(self):
        with patch.object(conflicts.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '', '{"InvalidGrammar": "bad"}')):
            with self.assertRaisesRegex(ValueError, 'not a supported conflict'):
                self.run_discovery()

    def test_repeated_conflicts_and_limit_fail_closed(self):
        diagnostic = json.dumps({'BuildTables': {'Conflict': {'possible_resolutions': [{'AddConflict': {'symbols': ['a', 'b']}}], 'symbol_sequence': ['x'], 'conflicting_lookahead': 'y'}}})
        with patch.object(conflicts.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '', diagnostic)):
            with self.assertRaisesRegex(ValueError, 'already declared'):
                self.run_discovery()
            with self.assertRaisesRegex(ValueError, 'exceeded'):
                self.run_discovery(limit=0)

    def test_no_conflicts_returns_an_empty_report(self):
        with tempfile.TemporaryDirectory(dir=ROOT) as temp:
            _, report = conflicts.discover(lambda groups: 'module.exports = grammar({name:"example", rules:{source_file:$=>"x"}});', {'grammars': [{'name': 'example', 'path': '.'}], 'metadata': {'version': '0.1.0'}}, temp, self.cli)
            self.assertEqual(report['conflicts'], [])

    def test_zane_conflicts_are_recomputed_from_shared_source(self):
        result = outputs(ROOT / 'grammar', os.environ.get('MENHIR', 'menhir'))
        report = json.loads(result['editors/tree-sitter-zane/conflicts.json'])
        # Keeping qualified names as nodes removes the type_expr /
        # unbraced_verb_call conflict from the original flattened editor tree.
        self.assertEqual(len(report['conflicts']), 19)
        self.assertEqual(len({tuple(c['rules']) for c in report['conflicts']}), 19)
        # No generated file or authored conflict list is read by discovery.
        self.assertIn('conflicts: $ => [', result['editors/tree-sitter-zane/grammar.js'])

    def test_shared_production_edit_introduces_a_new_generated_conflict(self):
        with tempfile.TemporaryDirectory(dir=ROOT) as temp:
            directory = Path(temp)
            shutil.copy(ROOT / 'grammar/lexicon.coda', directory)
            (directory / 'tree-sitter.coda').write_text('version 1\n')
            syntax = directory / 'syntax.mly'
            header = '(* @generated-tokens *)\n%start <unit> main\n%%\n'
            syntax.write_text(header + 'main: INT EOF { () }\n')
            before = outputs(directory, os.environ.get('MENHIR', 'menhir'))
            self.assertEqual(json.loads(before['editors/tree-sitter-zane/conflicts.json'])['conflicts'], [])
            syntax.write_text(header + '''main:
              | short PLUS MINUS EOF { () }
              | long PLUS EOF { () }
            short: INT { () }
            long: INT PLUS STAR { () }
            ''')
            after = outputs(directory, os.environ.get('MENHIR', 'menhir'))
            groups = [c['rules'] for c in json.loads(after['editors/tree-sitter-zane/conflicts.json'])['conflicts']]
            self.assertEqual(groups, [['_long', '_short']])
            self.assertNotEqual(before['lib/cst/parser.mly'], after['lib/cst/parser.mly'])
