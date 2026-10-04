"""Generate compiler/editor syntax from grammar/; --check verifies committed outputs."""
from __future__ import annotations

import argparse
import difflib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from . import conflicts, lexical, menhir, source, treesitter

ROOT = Path(__file__).resolve().parents[2]


def load(directory: Path):
    spec, overlay = source.load(directory)
    if spec.get('version') != 1 or overlay.get('version') != 1:
        raise ValueError('unsupported grammar specification version')
    if not re.fullmatch('[a-z][a-z0-9_]*', spec['language']):
        raise ValueError('invalid language name')
    if not spec['extensions'] or any(not isinstance(e, str) or not e for e in spec['extensions']):
        raise ValueError('extensions must be nonempty strings')
    for collection, key in ((spec['tokens'], 'name'), (spec['trivia'], 'name')):
        names = [item[key] for item in collection]
        if len(names) != len(set(names)):
            raise ValueError(f'duplicate {key}')
        if any(not re.fullmatch('[A-Za-z_][A-Za-z_0-9]*', n) for n in names):
            raise ValueError(f'invalid {key}')
    for t in spec['tokens']:
        if sum(k in t for k in ('literal', 'pattern', 'eof')) != 1:
            raise ValueError(f"token {t['name']} must have one of literal, pattern, eof")
        if 'literal' in t and (not isinstance(t['literal'], str) or not t['literal']):
            raise ValueError('literal tokens require nonempty spellings')
        if 'eof' in t and t['eof'] is not True:
            raise ValueError('eof must be true')
        if 'pattern' in t and (t.get('type') != 'string' or 'node' not in t):
            raise ValueError('pattern tokens require string payloads and node names')
        if 'pattern' not in t and 'type' in t:
            raise ValueError('only pattern tokens can carry payloads')
        if 'pattern' in t and not isinstance(t.get('example'), str):
            raise ValueError('pattern tokens require an example alias')
        if 'pattern' not in t and 'example' in t:
            raise ValueError('literal aliases are derived from their spelling; EOF uses <eof>')
        if not t.get('eof') and not all(k in t for k in ('capture', 'scope')):
            raise ValueError('tokens require highlighting metadata')
        if t.get('value') not in (None, 'unquote'):
            raise ValueError('unsupported token value transformation')
        if t.get('value') == 'unquote' and t.get('type') != 'string':
            raise ValueError('unquote requires a string token')
        if not t.get('eof') and 'pattern' in t:
            for backend in ('sedlex', 'regex'):
                lexical.render(t['pattern'], spec['expressions'], backend)
    if len([t for t in spec['tokens'] if t.get('value') == 'unquote']) != 1:
        raise ValueError('exactly one quoted string token is supported')
    nodes = [t['node'] for t in spec['tokens'] if 'node' in t] + [t['name'] for t in spec['trivia'] if 'capture' in t]
    literals = [t['literal'] for t in spec['tokens'] if 'literal' in t]
    if len(nodes) != len(set(nodes)) or len(literals) != len(set(literals)):
        raise ValueError('duplicate token nodes or literal spellings')
    if any(not re.fullmatch('[a-z][a-z0-9_]*', n) for n in nodes):
        raise ValueError('invalid token node name')
    for trivia in spec['trivia']:
        for backend in ('sedlex', 'regex'):
            lexical.render(trivia['pattern'], spec['expressions'], backend)
    if sum(bool(t.get('eof')) for t in spec['tokens']) != 1:
        raise ValueError('exactly one EOF token is required')
    # Validate every lexical definition, including unused definitions.
    for name in spec['expressions']:
        for backend in ('sedlex', 'regex'):
            lexical.render({'ref': name}, spec['expressions'], backend)
    return spec, overlay


def outputs(directory: Path, executable: str, tree_sitter=None):
    spec, overlay = load(directory)
    parser = menhir.generate((directory / 'syntax.mly').read_text(), spec)
    # Keep temporary files local to the invocation's workspace.
    with tempfile.TemporaryDirectory(prefix='zane-grammar-', dir=os.getcwd()) as temp:
        source = Path(temp) / 'parser.mly'
        source.write_text(parser)
        proc = subprocess.run([executable, '--only-preprocess-uu', str(source)], capture_output=True, text=True, timeout=120)
        if proc.returncode:
            raise ValueError('Menhir expansion failed:\n' + proc.stderr)
    start, rules, precedence = menhir.read_expanded(proc.stdout)
    config = {'grammars': [{'name': spec['language'], 'camelcase': 'Zane', 'scope': 'source.zane', 'path': '.', 'file-types': spec['extensions'], 'highlights': 'queries/highlights.scm'}], 'metadata': {'version': '0.1.0', 'license': 'GPL-3.0-only', 'description': 'Zane grammar generated from the compiler grammar', 'authors': [{'name': 'Zane contributors'}], 'links': {'repository': 'https://github.com/zane-lang/compiler'}}, 'bindings': {'c': True}}
    cli = conflicts.executable(tree_sitter or os.environ.get('TREE_SITTER'))
    render = lambda groups: treesitter.generate(spec, start, rules, precedence, overlay, groups)[0]
    with tempfile.TemporaryDirectory(prefix='zane-tree-sitter-', dir=os.getcwd()) as temp:
        grammar, report = conflicts.discover(render, config, temp, cli)
    _, queries = treesitter.generate(spec, start, rules, precedence, overlay)
    lua = '-- Generated by tools.grammar.\nvim.filetype.add({ extension = { ' + ', '.join('[' + lexical.quoted(e) + '] = "zane"' for e in spec['extensions']) + ' } })\nvim.api.nvim_create_autocmd("FileType", {\n  pattern = "zane",\n  -- A missing parser must not stop the buffer from opening.\n  callback = function(args) pcall(vim.treesitter.start, args.buf, "zane") end,\n})\n'
    package = {'name': 'tree-sitter-zane', 'version': '0.1.0', 'private': True, 'license': 'GPL-3.0-only', 'scripts': {'generate': 'tree-sitter generate', 'build': 'tree-sitter build --output zane.so'}, 'devDependencies': {'tree-sitter-cli': conflicts.VERSION}}
    return {'lib/cst/parser.mly': parser, 'lib/cst/lexer.ml': lexical.lexer(spec), 'editors/tree-sitter-zane/grammar.js': grammar, 'editors/tree-sitter-zane/conflicts.json': json.dumps(report, indent=2) + '\n', 'editors/tree-sitter-zane/tree-sitter.json': json.dumps(config, indent=2) + '\n', 'editors/tree-sitter-zane/package.json': json.dumps(package, indent=2) + '\n', 'editors/tree-sitter-zane/queries/highlights.scm': queries, 'editors/typst/Zane.sublime-syntax': lexical.sublime(spec), 'editors/neovim/zane.lua': lua}


def main(argv=None):
    args = argparse.ArgumentParser(description=__doc__)
    args.add_argument('--source', type=Path, default=ROOT / 'grammar')
    args.add_argument('--output-root', type=Path, default=ROOT)
    args.add_argument('--menhir', default=os.environ.get('MENHIR', 'menhir'))
    args.add_argument('--tree-sitter', help='path to the pinned Tree-sitter CLI (or set TREE_SITTER)')
    args.add_argument('--check', action='store_true', help='fail if committed outputs have drifted; write nothing')
    opts = args.parse_args(argv)
    try:
        generated = outputs(opts.source, opts.menhir, opts.tree_sitter)
        stale = []
        # Compute every output successfully before touching any existing file.
        for name, text in generated.items():
            path = opts.output_root / name
            old = path.read_text() if path.exists() else ''
            if old == text:
                continue
            stale.append(name)
            if opts.check:
                print('stale generated file: ' + name, file=sys.stderr)
                print(''.join(difflib.unified_diff(old.splitlines(True), text.splitlines(True), fromfile=name, tofile='generated/' + name)), file=sys.stderr)
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text)
                print('generated ' + name)
        return int(opts.check and bool(stale))
    except (ValueError, KeyError, TypeError, OSError, subprocess.TimeoutExpired) as error:
        print('grammar: ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
