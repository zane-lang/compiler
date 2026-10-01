"""Exact visible proof: count preservation, unlimited recursion, and certificates."""
from collections import defaultdict
import copy
import itertools
import json
import os
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest

from tools.ambiguity.visible.verify import verify

ROOT = Path(__file__).resolve().parents[2]
WORKERS = ROOT / "tools/ambiguity/visible"


def write_grammar(path, rules):
    terminals = sorted({x for rs in rules.values() for rhs in rs for x in rhs if x not in rules})
    path.write_text("%token " + " ".join(terminals) + "\n%start n0\n%%\n" +
                    "\n".join(n + " : " + " | ".join(" ".join(rhs) for rhs in rs) + " ;"
                              for n, rs in rules.items()) + "\n")


def grammar_count(rules, word):
    """Independent tree-height fixed point over all input spans (cap at two)."""
    length = len(word)
    counts = {(n, i, j): 0 for n in rules for i in range(length + 1) for j in range(i, length + 1)}
    while True:
        updated = {}
        for (n, i, j) in counts:
            total = 0
            for rhs in rules[n]:
                partial = {i: 1}
                for symbol in rhs:
                    following = defaultdict(int)
                    for begin, w in partial.items():
                        if symbol in rules:
                            for end in range(begin, j + 1):
                                following[end] = min(2, following[end] + w * counts[symbol, begin, end])
                        elif begin < j and word[begin] == symbol:
                            following[begin + 1] = min(2, following[begin + 1] + w)
                    partial = following
                total = min(2, total + partial.get(j, 0))
            updated[n, i, j] = total
        if updated == counts:
            return counts['n0', 0, length]
        counts = updated


def model_count(model, word):
    """Explicit finite-input VPA runs, including concrete return stacks."""
    fragments, edges = model['fragments'], model['edges']
    def close(initial):
        current = initial
        while True:
            new = dict(initial)
            for (q, stack), w in current.items():
                for e in edges[q]:
                    if e[0] == 'E':
                        key = e[1], stack
                        new[key] = min(2, new.get(key, 0) + w * e[2])
            if new == current:
                return new
            current = new
    current = {(fragments[0][0], ()): 1}
    for token in word:
        following = defaultdict(int)
        for (q, stack), w in close(current).items():
            for e in edges[q]:
                if e[0] == 'I' and e[1] == token:
                    key = e[2], stack
                    following[key] = min(2, following[key] + w)
                elif e[0] == 'C' and e[1] == token:
                    start, end = fragments[e[2]]
                    key = start, stack + ((end, e[3], e[4]),)
                    following[key] = min(2, following[key] + w)
            if stack and stack[-1][0] == q and stack[-1][2] == token:
                key = stack[-1][1], stack[:-1]
                following[key] = min(2, following[key] + w)
        current = following
    return close(current).get((fragments[0][1], ()), 0)


CASES = {
    'right_unique': ({'n0': [('n1', 'EOF')], 'n1': [(), ('INT', 'n1')]}, 0),
    'right_ambiguous': ({'n0': [('n1', 'EOF')], 'n1': [('INT',), ('INT', 'n1'), ('INT', 'INT', 'n1')]}, 1),
    'left_ambiguous': ({'n0': [('n1', 'EOF')], 'n1': [(), ('n1', 'INT'), ('n1', 'INT', 'INT')]}, 1),
    'epsilon_ambiguous': ({'n0': [('n1', 'EOF')], 'n1': [(), ()]}, 1),
    'unit_cycle': ({'n0': [('n1', 'EOF')], 'n1': [('n1',), ('INT',)]}, 1),
    'horizontal_split': ({'n0': [('n1', 'n2', 'EOF')], 'n1': [('INT',), ('INT', 'INT')], 'n2': [('INT',), ('INT', 'INT')]}, 1),
    'nested_unique': ({'n0': [('n1', 'EOF')], 'n1': [('INT',), ('LPAREN', 'n1', 'RPAREN')]}, 0),
    'overlapping_groups': ({'n0': [('n1', 'EOF'), ('n2', 'EOF')],
                            'n1': [('LPAREN', 'n3', 'RPAREN')], 'n2': [('LPAREN', 'n4', 'RPAREN')],
                            'n3': [('INT',)], 'n4': [('INT',)]}, 1),
    'disjoint_groups': ({'n0': [('n1', 'EOF'), ('n2', 'EOF')],
                         'n1': [('LPAREN', 'n3', 'RPAREN')], 'n2': [('LPAREN', 'n4', 'RPAREN')],
                         'n3': [('INT',)], 'n4': [('FALSE',)]}, 0),
}


class VisibleProofTests(unittest.TestCase):
    def worker(self, name, *arguments):
        return subprocess.run([sys.executable, WORKERS / name, *map(str, arguments)],
                              text=True, capture_output=True, timeout=20,
                              env={**os.environ, 'PYTHONHASHSEED': '0'})

    def test_verdicts_and_independent_parse_counts(self):
        for name, (rules, expected) in CASES.items():
            with self.subTest(name=name), TemporaryDirectory() as directory:
                root = Path(directory)
                grammar, model_path, cert = root / 'grammar.y', root / 'model.json', root / 'cert.json'
                write_grammar(grammar, rules)
                result = self.worker('prove.py', grammar, 100000, 10, cert)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                if expected == 0:
                    self.assertTrue(cert.exists())
                    verify(cert, grammar)
                else:
                    self.assertIn('AMBIGUOUS', result.stdout)
                    self.assertFalse(cert.exists())
                result = self.worker('dump.py', grammar, model_path)
                self.assertEqual(result.returncode, 0, result.stderr)
                model = json.loads(model_path.read_text())
                alphabet = sorted({t for rs in rules.values() for rhs in rs for t in rhs if t not in rules and t != 'EOF'})
                for length in range(5):
                    for body in itertools.product(alphabet, repeat=length):
                        word = (*body, 'EOF')
                        self.assertEqual(model_count(model, word), grammar_count(rules, word), (name, word))
                if name == 'nested_unique':
                    word = ('LPAREN',) * 100 + ('INT',) + ('RPAREN',) * 100 + ('EOF',)
                    self.assertEqual(model_count(model, word), 1)

    def test_factoring_preserves_counts(self):
        rules = {'n0': [('INT', 'n1', 'EOF'), ('INT', 'n2', 'EOF')],
                 'n1': [(), ('FALSE',)], 'n2': [(), ('INT',)]}
        with TemporaryDirectory() as directory:
            root = Path(directory); original = root / 'original.y'; factored = root / 'factored.y'
            write_grammar(original, rules)
            result = self.worker('factor.py', original, factored)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = self.worker('dump.py', factored, root / 'model.json')
            self.assertEqual(result.returncode, 0, result.stderr)
            model = json.loads((root / 'model.json').read_text())
            for length in range(5):
                for body in itertools.product(('INT', 'FALSE'), repeat=length):
                    word = (*body, 'EOF')
                    self.assertEqual(model_count(model, word), grammar_count(rules, word))

    def test_limits_and_unsupported_grammars_do_not_prove(self):
        with TemporaryDirectory() as directory:
            root = Path(directory); grammar = root / 'grammar.y'; cert = root / 'cert.json'
            write_grammar(grammar, CASES['nested_unique'][0])
            result = self.worker('prove.py', grammar, 1, 10, cert)
            self.assertEqual(result.returncode, 2)
            self.assertIn('NOT_PROVEN', result.stdout)
            self.assertFalse(cert.exists())
            write_grammar(grammar, {'n0': [('n1', 'EOF')], 'n1': [(), ('INT', 'n1', 'FALSE')]})
            result = self.worker('prove.py', grammar, 10000, 10, cert)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(cert.exists())

    def test_certificate_rejects_missing_successors_and_wrong_hash(self):
        with TemporaryDirectory() as directory:
            root = Path(directory); grammar = root / 'grammar.y'; cert = root / 'cert.json'
            write_grammar(grammar, CASES['nested_unique'][0])
            self.assertEqual(self.worker('prove.py', grammar, 10000, 10, cert).returncode, 0)
            data = json.loads(cert.read_text())
            tampered = copy.deepcopy(data)
            tampered['frames'][0]['nodes'].pop()
            cert.write_text(json.dumps(tampered))
            with self.assertRaises(ValueError):
                verify(cert, grammar)
            cert.write_text(json.dumps(data)); grammar.write_text(grammar.read_text() + '\n')
            with self.assertRaisesRegex(ValueError, 'hash'):
                verify(cert, grammar)


class VisiblePipelineTests(unittest.TestCase):
    def test_menhir_precedence_and_both_backend_modes(self):
        from tools.ambiguity.visible.run import run
        menhir = os.environ.get('AMBIGUITY_MENHIR')
        if not menhir:
            self.skipTest('set AMBIGUITY_MENHIR to test Menhir preprocessing')
        source = "%token INT EOF PLUS STAR LPAREN RPAREN\n%left PLUS\n%left STAR\n%start <unit> package\n%%\npackage: expr EOF {()}\nexpr: INT {()} | expr PLUS expr {()} | expr STAR expr {()} | LPAREN expr RPAREN {()}\n"
        with TemporaryDirectory() as directory:
            root = Path(directory); grammar = root / 'grammar.mly'; grammar.write_text(source)
            for stock in (True, False):
                with self.subTest(stock=stock):
                    out = root / str(stock)
                    self.assertEqual(run(grammar, out, menhir, stock, 20), 0)
                    verify(out / 'certificate.json', out / 'factored.y')

    def test_ambiguity_and_duplicate_production_shapes_fail_closed(self):
        from tools.ambiguity.visible.run import run
        menhir = os.environ.get('AMBIGUITY_MENHIR')
        if not menhir:
            self.skipTest('set AMBIGUITY_MENHIR to test Menhir preprocessing')
        prefix = '%token INT EOF\n%start <unit> package\n%%\npackage: expr EOF {()}\n'
        with TemporaryDirectory() as directory:
            root = Path(directory); grammar = root / 'grammar.mly'
            grammar.write_text(prefix + 'expr: INT {()} | INT expr {()} | INT INT expr {()}\n')
            self.assertEqual(run(grammar, root / 'ambiguous', menhir, True, 20), 1)
            self.assertFalse((root / 'ambiguous/certificate.json').exists())
            grammar.write_text(prefix + 'expr: INT {()} | INT {()}\n')
            self.assertEqual(run(grammar, root / 'duplicate', menhir, True, 20), 3)
            self.assertFalse((root / 'duplicate/certificate.json').exists())


if __name__ == '__main__':
    unittest.main()
