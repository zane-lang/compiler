"""Discover GLR declarations from the translated grammar using the pinned CLI."""
from __future__ import annotations

import json
from pathlib import Path
import re
import shutil
import subprocess

VERSION = '0.25.10'
ABI = 15


def executable(explicit=None):
    candidate = (shutil.which(explicit) or explicit) if explicit else shutil.which('tree-sitter')
    if not candidate:
        candidate = Path(__file__).resolve().parents[2] / 'editors/tree-sitter-zane/node_modules/.bin/tree-sitter'
    candidate = str(Path(candidate).resolve())
    try:
        result = subprocess.run([candidate, '--version'], capture_output=True, text=True, timeout=10)
    except OSError as error:
        raise ValueError('Tree-sitter CLI required; run npm ci --prefix editors/tree-sitter-zane') from error
    if result.returncode or not re.match(r'tree-sitter ' + re.escape(VERSION) + r'(?:\s|$)', result.stdout, re.IGNORECASE):
        raise ValueError(f'Tree-sitter CLI {VERSION} required; found {result.stdout.strip() or result.stderr.strip()}')
    return candidate


def discover(render, config, directory, cli, limit=128):
    """Start from no declarations; retain every reported competing parse.

    Use AddConflict recommendations only: precedence/associativity changes
    would make choices not present in the shared source. Never retry other
    errors or consume previously generated declarations as input.
    """
    directory = Path(directory)
    (directory / 'tree-sitter.json').write_text(json.dumps(config))
    groups = []
    evidence = []
    for attempt in range(limit + 1):
        grammar = render(groups)
        (directory / 'grammar.js').write_text(grammar)
        result = subprocess.run([cli, 'generate', '--json', '--abi', str(ABI)], cwd=directory,
                                capture_output=True, text=True, timeout=120)
        if not result.returncode:
            return grammar, {'generator': f'tree-sitter {VERSION}', 'abi': ABI, 'conflicts': evidence}
        try:
            conflict = json.loads(result.stderr)['BuildTables']['Conflict']
            resolutions = [r['AddConflict']['symbols'] for r in conflict['possible_resolutions'] if 'AddConflict' in r]
            if len(resolutions) != 1:
                raise ValueError('expected exactly one AddConflict recommendation')
            group = sorted(set(resolutions[0]))
            if not group or any(not isinstance(n, str) for n in group):
                raise ValueError('invalid conflict symbols')
            sequence = conflict['symbol_sequence']
            lookahead = conflict['conflicting_lookahead']
        except (ValueError, KeyError, TypeError) as error:
            raise ValueError('Tree-sitter generation failed (not a supported conflict):\n' + result.stderr) from error
        if group in groups:
            raise ValueError('Tree-sitter repeated an already declared conflict: ' + repr(group))
        if attempt == limit:
            raise ValueError(f'Tree-sitter conflict discovery exceeded {limit} groups')
        groups.append(group)
        groups.sort()
        evidence.append({'rules': group, 'symbol_sequence': sequence, 'lookahead': lookahead})
    raise AssertionError('unreachable')
