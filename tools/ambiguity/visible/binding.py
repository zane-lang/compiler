"""Compare counted VPA models independently of state and fragment numbering."""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory


def fragment_colors(model: dict, side: int, f: int, entry, end) -> dict:
    """The first colors of the states fragment [f] reaches: final or not.

    Local states carry the active fragment, so acceptance is an observable
    label even when two global dead states look alike.
    """
    colors = {}
    pending = [entry, end]
    while pending:
        q = pending.pop()
        if (side, f, q) in colors:
            continue
        colors[side, f, q] = int(q == end)
        for e in model['edges'][q]:
            pending.append(e[1] if e[0] == 'E' else e[2] if e[0] == 'I' else e[3])
    return colors


def alternative(colors: dict, side: int, kind, e: tuple) -> tuple:
    """Edge [e] as the colors it leads to, the shape refinement compares."""
    if e[0] == 'E':
        return ('E', e[2], colors[side, kind, e[1]])
    if e[0] == 'I':
        return ('I', e[1], colors[side, kind, e[2]])
    if e[0] == 'C':
        return ('C', e[1], colors[side, 'f', e[2]], colors[side, kind, e[3]], e[4])
    raise ValueError('unknown model edge')


def equivalent_models(left: dict, right: dict) -> bool:
    """Weighted strong bisimulation; repeated alternatives stay repeated.

    Fragment nodes expose both entry and final states. A call signature binds
    its fragment and continuation together, rather than comparing projections.
    Bisimulation preserves capped path counts for every structured input word.
    This sufficient equivalence check deliberately fails closed when it cannot
    match two models; it is not a general VPA language-equivalence solver.
    """
    models = (left, right)
    colors = {}
    for side, model in enumerate(models):
        for f, (entry, end) in enumerate(model['fragments']):
            colors[side, 'f', f] = 2
            colors.update(fragment_colors(model, side, f, entry, end))
    while True:
        signatures = {}
        updated = {}
        for node, old in colors.items():
            side, kind, index = node
            model = models[side]
            if kind == 'f':
                entry, end = model['fragments'][index]
                shape = ('F', colors[side, index, entry], colors[side, index, end])
            else:
                alternatives = [alternative(colors, side, kind, e) for e in model['edges'][index]]
                shape = ('Q', index == model['fragments'][kind][1], tuple(sorted(alternatives)))
            signature = old, shape
            if signature not in signatures:
                signatures[signature] = len(signatures)
            updated[node] = signatures[signature]
        # Refinement includes the previous color and thus cannot merge classes.
        if len(signatures) == len(set(colors.values())):
            return updated[0, 'f', 0] == updated[1, 'f', 0]
        colors = updated


def verify_model_binding(model: dict, grammar: Path, seconds: int = 300) -> None:
    """Recompile the grammar without consulting certificate vectors or frames."""
    here = Path(__file__).resolve().parent
    with TemporaryDirectory(prefix='visible-model-check-') as directory:
        output = Path(directory) / 'model.json'
        result = subprocess.run(
            [sys.executable, here / 'dump.py', grammar.resolve(), output],
            capture_output=True, text=True, encoding='utf-8', timeout=seconds,
            env={**os.environ, 'PYTHONHASHSEED': '0', 'PYTHONUTF8': '1', 'PYTHONIOENCODING': 'utf-8'},
        )
        if result.returncode:
            raise ValueError('model rebuild failed: ' + result.stderr[-2000:])
        rebuilt = json.loads(output.read_text())
    if not equivalent_models(model, rebuilt):
        raise ValueError('certificate model does not match the rebuilt grammar model')
