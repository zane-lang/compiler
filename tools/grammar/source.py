"""Read Coda structures; interpret only fields with schema-defined types."""
from __future__ import annotations

from pathlib import Path


def read(path: Path):
    try:
        import coda
    except ImportError as error:
        raise ValueError('Coda parser required; install tools/grammar/requirements.txt') from error

    def value(node):
        if isinstance(node, (coda.Block, coda.Row)):
            return {key: value(child) if isinstance(child, coda.Node) else child for key, child in node}
        if isinstance(node, (coda.Array, coda.Table)):
            return [value(child) for child in node]
        if isinstance(node, coda.KeyedTable):
            return {key: value(row) for key, row in node}
        return str(node)

    try:
        with coda.Doc.parse_file(str(path)) as doc:
            return value(doc.root())
    except coda.Error as error:
        raise ValueError(f'{path}: {error}') from error


def integer(text, field):
    if not isinstance(text, str) or not text.isascii() or not text.isdecimal():
        raise ValueError(f'{field} must be a nonnegative integer')
    return int(text)


def boolean(text, field):
    if text not in ('true', 'false'):
        raise ValueError(f'{field} must be true or false')
    return text == 'true'


def expression(expr):
    if not isinstance(expr, dict) or len(expr) != 1:
        raise ValueError('Coda lexical expressions require one operator per block')
    op, item = next(iter(expr.items()))
    if op == 'literal':
        if not isinstance(item, str):
            raise ValueError('literal expression must be a string')
        return item
    if op in ('seq', 'choice'):
        if not isinstance(item, list):
            raise ValueError(f'{op} requires an array of expression blocks')
        item = [expression(e) for e in item]
    elif op in ('star', 'plus', 'optional'):
        item = expression(item)
    elif op == 'any':
        item = boolean(item, 'any')
    return {op: item}


def load(directory):
    spec = read(directory / 'lexicon.coda')
    overlay = read(directory / 'tree-sitter.coda')
    for document in (spec, overlay):
        document['version'] = integer(document['version'], 'version')
    if 'conflicts' in overlay:
        raise ValueError('conflicts are discovered automatically; remove authored declarations')
    spec['expressions'] = {name: expression(expr) for name, expr in spec['expressions'].items()}
    patterns = spec.pop('pattern_tokens')
    literals = spec.pop('literal_tokens')
    eof = spec.pop('eof_token')
    eof['eof'] = boolean(eof['eof'], 'eof')
    spec['tokens'] = [*patterns, *literals, eof]
    for item in [*patterns, *spec['trivia']]:
        item['pattern'] = expression(item['pattern'])
        if 'highlight_priority' in item:
            item['highlight_priority'] = integer(item['highlight_priority'], 'highlight_priority')
    return spec, overlay
