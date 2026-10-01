"""Check a closed weighted VPA invariant without running the proof search."""
from __future__ import annotations

import argparse
from collections import defaultdict
import hashlib
import json
from pathlib import Path

BRACKETS = {"LPAREN": "RPAREN", "LBRACKET": "RBRACKET", "LCURLY": "RCURLY", "GLESS": "GMORE"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify(certificate: Path, grammar: Path | None = None) -> dict:
    data = json.loads(certificate.read_text())
    require(data.get("schema") == 1, "unknown certificate schema")
    if grammar is not None:
        require(hashlib.sha256(grammar.read_bytes()).hexdigest() == data["grammar_sha256"], "grammar hash mismatch")
    edges = data["model"]["edges"]
    fragments = data["model"]["fragments"]
    size = len(edges)
    require(size > 0 and len(fragments) > 0, "empty model")
    ends = set()
    for entry, end in fragments:
        require(0 <= entry < size and 0 <= end < size, "invalid fragment state")
        require(not edges[end], "fragment end has outgoing edges")
        ends.add(end)
    for es in edges:
        for e in es:
            if e[0] == "E":
                require(len(e) == 3 and 0 <= e[1] < size and e[2] in (1, 2), "invalid epsilon edge")
            elif e[0] == "I":
                require(len(e) == 3 and 0 <= e[2] < size, "invalid internal edge")
                require(e[1] not in BRACKETS and e[1] not in BRACKETS.values(), "delimiter is internal")
            elif e[0] == "C":
                require(len(e) == 5 and 0 <= e[2] < len(fragments) and 0 <= e[3] < size, "invalid call edge")
                require(BRACKETS.get(e[1]) == e[4], "invalid call delimiter pair")
            else:
                raise ValueError("unknown model edge")

    # Independently compute epsilon path counts by bounded-path fixed points.
    # Iteration i counts paths of length <= i, rather than propagating deltas.
    closure_cache = {}

    def normalize(counts):
        initial = {key: min(2, value) for key, value in counts.items() if value}
        cache_key = tuple(sorted(initial.items()))
        if cache_key in closure_cache:
            return closure_cache[cache_key]
        current = initial
        while True:
            updated = dict(initial)
            for (f, q), value in current.items():
                for e in edges[q]:
                    if e[0] == "E":
                        key = f, e[1]
                        updated[key] = min(2, updated.get(key, 0) + value * e[2])
            if updated == current:
                break
            current = updated
        result = tuple(sorted((f, q, value) for (f, q), value in current.items()
                              if q in ends or any(e[0] != "E" for e in edges[q])))
        closure_cache[cache_key] = result
        return result

    vectors = []
    for v in data["vectors"]:
        v = tuple(tuple(row) for row in v)
        require(v == tuple(sorted(v)) and len({(f, q) for f, q, w in v}) == len(v), "invalid vector ordering")
        for f, q, w in v:
            require(0 <= f < len(fragments) and 0 <= q < size and w in (1, 2), "invalid vector entry")
            require(q in ends or any(e[0] != "E" for e in edges[q]), "vector retains an epsilon-only state")
        vectors.append(v)
    require(len(set(vectors)) == len(vectors), "duplicate vectors")
    frames = {}
    for fr in data["frames"]:
        fs, closer = fr["key"]
        key = tuple(fs), closer
        require(key not in frames and fs == sorted(set(fs)), "duplicate or unordered frame")
        require(all(0 <= f < len(fragments) for f in fs), "invalid frame fragment")
        require(closer is None or closer in BRACKETS.values(), "invalid frame closer")
        require(all(0 <= v < len(vectors) for v in fr["nodes"]), "invalid frame vector index")
        nodes = {vectors[v] for v in fr["nodes"]}
        exits = {tuple(tuple(row) for row in ex) for ex in fr["exits"]}
        require(normalize({(f, fragments[f][0]): 1 for f in fs}) in nodes, "missing frame entry")
        frames[key] = nodes, exits
    root = ((0,), None)
    require(root in frames, "missing root frame")

    for frame_key, (nodes, claimed_exits) in frames.items():
        actual_exits = set()
        for v in nodes:
            require(all(f in frame_key[0] for f, q, w in v), "foreign fragment in frame")
            accepted = defaultdict(int)
            internals = {}
            calls = {}
            for f, q, w in v:
                if q == fragments[f][1]:
                    accepted[f] = min(2, accepted[f] + w)
                for e in edges[q]:
                    if e[0] == "I":
                        counts = internals.setdefault(e[1], defaultdict(int))
                        counts[f, e[2]] = min(2, counts[f, e[2]] + w)
                    elif e[0] == "C":
                        counts = calls.setdefault(e[1], defaultdict(int))
                        key = f, e[2], e[3], e[4]
                        counts[key] = min(2, counts[key] + w)
            accepted = tuple(sorted(accepted.items()))
            if accepted:
                actual_exits.add(accepted)
                require(frame_key != root or dict(accepted).get(0, 0) < 2, "root accepts two parses")
            for counts in internals.values():
                require(normalize(counts) in nodes, "missing internal successor")
            for opening, context in calls.items():
                child_key = tuple(sorted({cf for pf, cf, ret, close in context})), BRACKETS[opening]
                require(child_key in frames, "missing child frame")
                for accepted in frames[child_key][1]:
                    weights = dict(accepted)
                    result = defaultdict(int)
                    for (pf, cf, ret, close), w in context.items():
                        require(close == child_key[1], "wrong return delimiter")
                        result[pf, ret] = min(2, result[pf, ret] + w * weights.get(cf, 0))
                    if any(result.values()):
                        require(normalize(result) in nodes, "missing return successor")
        require(actual_exits == claimed_exits, "incorrect frame exit summaries")
    return {"configurations": sum(len(nodes) for nodes, exits in frames.values()), "frames": len(frames), "model_states": size}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("certificate", type=Path)
    parser.add_argument("--grammar", type=Path)
    args = parser.parse_args()
    try:
        result = verify(args.certificate, args.grammar)
    except (ValueError, KeyError, IndexError, TypeError) as exc:
        parser.exit(2, f"INVALID CERTIFICATE: {exc}\n")
    print("VERIFIED:", json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
