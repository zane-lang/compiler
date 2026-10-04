"""Preserve the compiler's reserved-word priority in contextual editor lexing.

Tree-sitter's single `word` token cannot represent both Zane identifier casing
classes. Compile the finite keyword exclusion into each identifier regex.
"""
from __future__ import annotations

import re

from .lexical import render


def expand(expr, definitions):
    if isinstance(expr, str):
        return expr
    op, value = next(iter(expr.items()))
    if op == 'ref':
        return expand(definitions[value], definitions)
    if op in ('seq', 'choice'):
        return {op: [expand(e, definitions) for e in value]}
    if op in ('star', 'plus', 'optional'):
        return {op: expand(value, definitions)}
    return expr


def contains(char, expr):
    if isinstance(expr, str):
        return char == expr
    op, value = next(iter(expr.items()))
    if op == 'unicode':
        return {'alphabetic': str.isalpha, 'lowercase': str.islower, 'uppercase': str.isupper}[value](char)
    if op == 'range':
        return value[0] <= char <= value[1]
    if op == 'not':
        return char not in value
    if op == 'any':
        return True
    if op == 'choice':
        return any(contains(char, e) for e in value)
    raise ValueError('identifier character sets must be single-character expressions')


def char_class(expr):
    if isinstance(expr, dict) and 'choice' in expr:
        return '[' + ''.join(char_class(e) for e in expr['choice']) + ']'
    return render(expr, {}, 'regex')


def is_char_class(expr):
    if isinstance(expr, str):
        return len(expr) == 1
    op, value = next(iter(expr.items()))
    if op == 'choice':
        return all(is_char_class(e) for e in value)
    return op in ('unicode', 'range', 'not', 'any')


def excluding(first, rest, words):
    trie = {}
    for word in words:
        node = trie
        for char in word:
            node = node.setdefault(char, {})
        node[None] = True
    alternatives = []
    rest_class = char_class(rest)

    def walk(node, prefix):
        children = [c for c in node if c is not None]
        if prefix and None not in node:
            alternatives.append(re.escape(prefix))
        charset = char_class(first) if not prefix else rest_class
        if children:
            charset = '[' + charset + '--[' + ''.join(re.escape(c) for c in children) + ']]'
        alternatives.append(re.escape(prefix) + charset + rest_class + '*')
        for char in children:
            walk(node[char], prefix + char)

    walk(trie, '')
    return '(?:' + '|'.join(alternatives) + ')'


def pattern(token, spec):
    expr = expand(token['pattern'], spec['expressions'])
    ordinary = render(expr, {}, 'regex')
    # Zane's two identifier classes use a prefix choice and a repeated
    # continuation class. Other token shapes do not overlap keyword spellings.
    if not isinstance(expr, dict) or 'seq' not in expr or len(expr['seq']) != 2:
        return ordinary
    prefix, tail = expr['seq']
    if not isinstance(tail, dict) or 'star' not in tail:
        return ordinary
    rest = tail['star']
    if not is_char_class(rest):
        return ordinary
    branches = prefix.get('choice', [prefix]) if isinstance(prefix, dict) else [prefix]
    literals = [t['literal'] for t in spec['tokens'] if 'literal' in t and t['literal'].isalpha()]
    patterns = []
    for branch in branches:
        # A privacy prefix such as '_' followed by a casing class cannot
        # equal an alphabetic keyword, so retain that branch verbatim.
        if isinstance(branch, dict) and 'seq' in branch:
            patterns.append(render({'seq': [branch, tail]}, {}, 'regex'))
            continue
        if not is_char_class(branch):
            return ordinary
        words = [w for w in literals if contains(w[0], branch) and all(contains(c, rest) for c in w[1:])]
        patterns.append(excluding(branch, rest, words) if words else render({'seq': [branch, tail]}, {}, 'regex'))
    return '(?:' + '|'.join(patterns) + ')'
