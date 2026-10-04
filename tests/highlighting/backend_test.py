"""Exercise actual generated parsers and consumers, not just output strings."""
import ctypes
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

from tools.grammar import conflicts
from tools.grammar.__main__ import ROOT
from tests.parser import syntax_test

try:
    from tree_sitter import Language, Parser, Query, QueryCursor
except ImportError:
    Language = None

SPAN_DUMP = ROOT / '_build/default/tools/inspect/span_dump.exe'

try:
    # The pinned CLI, found on PATH or where npm ci installs it.
    TREE_SITTER = conflicts.executable(os.environ.get('TREE_SITTER'))
except ValueError:
    TREE_SITTER = None


def needs(condition, reason):
    # CI sets this, so a missing tool fails the run instead of skipping its tests.
    if not condition and os.environ.get('ZANE_REQUIRE_HIGHLIGHTING_TOOLS'):
        raise RuntimeError(reason + ' (ZANE_REQUIRE_HIGHLIGHTING_TOOLS is set)')
    return unittest.skipUnless(condition, reason)


def cases(suite):
    for case in suite:
        if isinstance(case, unittest.TestSuite):
            yield from cases(case)
        else:
            yield case


def accepted_sources():
    """Every source the compiler's syntax suite expects to parse."""
    suite = unittest.defaultTestLoader.loadTestsFromModule(syntax_test)
    accepted = []
    for case in cases(suite):
        case.setUp = lambda: None
        case.assert_parses = lambda source: accepted.append(source.encode())
        case.assert_rejects = lambda source: None
    result = unittest.TestResult()
    suite.run(result)
    if result.errors or result.failures:
        raise AssertionError(result.errors + result.failures)
    return accepted


def check(command, **kwargs):
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=120, **kwargs)
    if result.returncode:
        raise AssertionError(result.stdout + result.stderr)
    return result


@needs(Language and TREE_SITTER and shutil.which('cc'), 'requires the pinned tree-sitter-cli, Python tree-sitter and a C compiler')
class BackendTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(dir=ROOT)
        cls.addClassCleanup(cls.temp.cleanup)
        cls.runtime = Path(cls.temp.name)
        source = ROOT / 'editors/tree-sitter-zane'
        result = subprocess.run([TREE_SITTER, 'generate'], cwd=source, capture_output=True, text=True, timeout=120)
        if result.returncode:
            raise AssertionError(result.stderr)
        (cls.runtime / 'parser').mkdir()
        library = cls.runtime / 'parser/zane.so'
        check(['cc', '-shared', '-fPIC', '-I', str(source / 'src'), str(source / 'src/parser.c'), '-o', str(library)])
        cls.lib = ctypes.CDLL(str(library))
        cls.lib.tree_sitter_zane.restype = ctypes.c_void_p
        # Use the capsule interface rather than deprecated integer pointers.
        capsule = ctypes.pythonapi.PyCapsule_New
        capsule.restype = ctypes.py_object
        capsule.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p]
        cls.language = Language(capsule(cls.lib.tree_sitter_zane(), b'tree_sitter.Language', None))
        cls.parser = Parser(cls.language)
        cls.query = Query(cls.language, (source / 'queries/highlights.scm').read_text())
        shutil.copytree(source / 'queries', cls.runtime / 'queries/zane')
        # Neovim's own captures extend the shared query from an `after` directory.
        shutil.copytree(ROOT / 'editors/neovim/queries', cls.runtime / 'after/queries')

    def test_existing_accepted_syntax_examples(self):
        # Reuse all accepted examples from the compiler's syntax suite. The
        # editor parser intentionally omits OCaml actions and Statement_check;
        # compiler rejection expectations are tested separately below.
        accepted = accepted_sources()
        for source in accepted:
            self.assertFalse(self.parser.parse(source).root_node.has_error, source)
        self.assertGreater(len(accepted), 50)

    def test_existing_parser_fixtures(self):
        for path in (ROOT / 'tests/parser/fixtures').glob('*.zn'):
            with self.subTest(path=path.name):
                self.assertFalse(self.parser.parse(path.read_bytes()).root_node.has_error)

    def test_reserved_words_and_invalid_identifier_spellings(self):
        for source in ('type Int = struct {}', 'type Intx = struct {}', 'type Résultat = struct {}', 'type _Type = struct {}', 'type Typex = struct {}', '_private Int = 1', '_return Int = 1', 'returning Int = 1'):
            self.assertFalse(self.parser.parse(source.encode()).root_node.has_error, source)
        for source in ('return Int = 1', 'type Type = struct {}', 'type type = struct {}', 'a_b Int = 1', 'x Int = 1.5.2', 'x Int = @@@'):
            self.assertTrue(self.parser.parse(source.encode()).root_node.has_error, source)

    def test_highlight_queries_capture_context_and_lexical_tokens(self):
        source = b'/// docs\nUnit main() { x Float = 3.14; f("return // type"); return Unit(); }'
        tree = self.parser.parse(source)
        self.assertFalse(tree.root_node.has_error)
        captures = QueryCursor(self.query).captures(tree.root_node)
        for capture in ('comment.documentation', 'type', 'function', 'function.call', 'number.float', 'string', 'keyword'):
            self.assertIn(capture, captures)
        self.assertEqual([source[n.start_byte:n.end_byte] for n in captures['number.float']], [b'3.14'])
        self.assertNotIn(b'type', [source[n.start_byte:n.end_byte] for n in captures['keyword']])

    def test_only_declared_verb_names_are_functions(self):
        # Anchors skip anonymous tokens, so an operator's or a lambda's first
        # parameter sits where a named verb's name does; neither is a function.
        cases = {
            b'Int +(a Int, b Int) => a': [],
            b'Int ~(a Int, b Int) => a': [],
            b'f Int(x Int) => x': [],
            b'Int f(x Int) => x': [b'f'],
            b'Int f(this T, y Int) mut { return y; }': [b'f'],
            b'Unit main() { Int g() => 1; h Int(y Int) => y; Unit k() => f() {} }': [b'main', b'g', b'k'],
        }
        for source, names in cases.items():
            with self.subTest(source=source):
                tree = self.parser.parse(source)
                self.assertFalse(tree.root_node.has_error)
                captures = QueryCursor(self.query).captures(tree.root_node)
                found = sorted((n.start_byte, source[n.start_byte:n.end_byte]) for n in captures.get('function', []))
                self.assertEqual([name for _, name in found], names)

    @needs(SPAN_DUMP.exists(), 'requires span_dump.exe')
    def test_parameter_captures_are_the_compilers_parameters(self):
        # The compiler's CST says which names are parameters; the shared query
        # captures every one of them where it is declared, and nothing else.
        # Uses are Neovim's own captures, checked by tests/highlighting/neovim.lua.
        sources = accepted_sources() + [p.read_bytes() for p in sorted((ROOT / 'tests/parser/fixtures').glob('*.zn'))]
        for source in sources:
            with self.subTest(source=source[:80]), tempfile.NamedTemporaryFile(suffix='.zn', dir=self.runtime) as file:
                file.write(source)
                file.flush()
                spans = check([str(SPAN_DUMP), '--cst', file.name]).stdout
                # Concept parameters are named in type case; those are types.
                expected = re.findall(r'^\s*(?:param|constructor_field) \| ([^\W\dA-Z]\w*)', spans, re.M)
                captures = QueryCursor(self.query).captures(self.parser.parse(source).root_node)
                nodes = sorted(captures.get('variable.parameter', []), key=lambda n: n.start_byte)
                self.assertEqual([source[n.start_byte:n.end_byte].decode() for n in nodes], expected)

    def test_comments_may_contain_backslashes(self):
        source = b'x Int = 1 // a \\ b\nUnit main() {}'
        tree = self.parser.parse(source)
        self.assertFalse(tree.root_node.has_error)
        captures = QueryCursor(self.query).captures(tree.root_node)
        self.assertEqual([source[n.start_byte:n.end_byte] for n in captures['comment']], [b'// a \\ b'])

    def test_incomplete_edits_recover_after_a_completed_declaration(self):
        source = b'type Int = struct {}\nUnit main() { f('
        tree = self.parser.parse(source)
        self.assertTrue(tree.root_node.has_error)
        captures = QueryCursor(self.query).captures(tree.root_node)
        self.assertIn(b'Int', [source[n.start_byte:n.end_byte] for n in captures['type']])

    @needs(shutil.which('nvim'), 'requires Neovim')
    def test_neovim_loads_parser_and_queries(self):
        check(['nvim', '--headless', '-u', 'NONE', '-l', str(ROOT / 'tests/highlighting/neovim.lua')], env={**os.environ, 'ZANE_TEST_ROOT': str(ROOT), 'ZANE_TEST_RUNTIME': str(self.runtime)})


@needs(shutil.which('typst'), 'requires Typst')
class TypstTests(unittest.TestCase):
    def test_generated_sublime_syntax_compiles_and_colours_code(self):
        import xml.etree.ElementTree as ET
        with tempfile.TemporaryDirectory(dir=ROOT) as temp:
            output = Path(temp) / 'example.svg'
            check(['typst', 'compile', '--root', str(ROOT), 'tests/highlighting/example.typ', str(output)])
            svg = ET.parse(output)
            colours = {e.attrib['fill'] for e in svg.iter() if 'fill' in e.attrib and e.attrib['fill'].startswith('#')}
            self.assertGreater(len(colours), 3, colours)


@needs((ROOT / '_build/default/tests/highlighting/parser_check.exe').exists(), 'requires parser_check.exe')
class CompilerTests(unittest.TestCase):
    def test_existing_acceptance_and_rejection_suite(self):
        previous = syntax_test.COMPILER
        try:
            syntax_test.COMPILER = ROOT / '_build/default/tests/highlighting/parser_check.exe'
            suite = unittest.defaultTestLoader.loadTestsFromModule(syntax_test)
            result = unittest.TestResult()
            suite.run(result)
            self.assertFalse(result.errors or result.failures, result.errors + result.failures)
            self.assertGreater(result.testsRun, 30)
        finally:
            syntax_test.COMPILER = previous
