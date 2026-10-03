"""Compile each horizontal SCC before substituting lower components."""
import sys, collections
from pathlib import Path
from regular import rules, components, directions, normalized, nonempty, EPS, product, of, bad
if bad:
    raise ValueError('horizontal grammar is not strongly regular')
DFAS = {}
STARTS = {}
ACCEPTS = {}
TRANS = {}
LANG = {}
LIB = []
LIBIDS = {}
for c in reversed(range(len(components))):
    members = components[c]
    direction = directions[c]
    nodes = []
    out = collections.defaultdict(list)

    def new():
        nodes.append(None)
        return len(nodes) - 1
    entries = {n: new() for n in members}
    start = new() if direction == 'left' else None
    end = new() if direction == 'right' else None
    heads = {}

    def seqhead(seq, tail):
        for x in reversed(seq):
            if isinstance(x, str) and x in rules and (x not in nonempty):
                if not EPS[x]:
                    raise ValueError('proof invariant failed')
                if EPS[x] > 1:
                    key = ('weight', tail)
                    if key not in heads:
                        q = new()
                        heads[key] = q
                        out[q].append(('E', tail, 2))
                    tail = heads[key]
                continue
            atom = ('N', x) if isinstance(x, str) and x in rules else ('T', x) if isinstance(x, str) else x
            key = (atom, tail)
            if key not in heads:
                q = new()
                heads[key] = q
                out[q].append(('A', atom, tail))
            tail = heads[key]
        return tail
    for n in members:
        for rhs in normalized[n]:
            same = [i for i, x in enumerate(rhs) if isinstance(x, str) and of.get(x) == c]
            if not same:
                origin = start if direction == 'left' else entries[n]
                dest = entries[n] if direction == 'left' else end
                body = rhs
                w = 1
            else:
                i = same[0]
                if not len(same) == 1:
                    raise ValueError('proof invariant failed')
                if direction == 'left':
                    origin = entries[rhs[i]]
                    dest = entries[n]
                    body = rhs[i + 1:]
                    w = product((EPS[x] for x in rhs[:i]))
                else:
                    origin = entries[n]
                    dest = entries[rhs[i]]
                    body = rhs[:i]
                    w = product((EPS[x] for x in rhs[i + 1:]))
            out[origin].append(('E', seqhead(body, dest), w))
    copies = {}

    def inline(lid, tail):
        key = (lid, tail)
        if key in copies:
            return copies[key][0]
        initial, lt, la = LIB[lid]
        mapping = {d: new() for d in lt}
        copies[key] = (mapping[initial], mapping)
        for d, edges in lt.items():
            q = mapping[d]
            if la[d]:
                out[q].append(('E', tail, la[d]))
            for atom, target in edges.items():
                out[q].append(('A', atom, mapping[target]))
        return mapping[initial]
    for q in list(out):
        changed = []
        for e in out[q]:
            if e[0] == 'A' and e[1][0] == 'N':
                changed.append(('E', inline(LANG[e[1][1]], e[2]), 1))
            else:
                changed.append(e)
        out[q] = changed
    finals = {q: n for n, q in entries.items()} if direction == 'left' else {end: 'end'}

    def close(counts):
        result = dict(counts)
        todo = collections.deque(counts.items())
        while todo:
            q, delta = todo.popleft()
            for e in out[q]:
                if e[0] == 'E':
                    _, r, w = e
                    old = result.get(r, 0)
                    new = min(2, old + delta * w)
                    if new > old:
                        result[r] = new
                        todo.append((r, new - old))
        return tuple(sorted(((q, w) for q, w in result.items() if q in finals or any((e[0] == 'A' for e in out[q])))))
    states = []
    ids = {}
    todo = collections.deque()
    trans = {}
    accepts = {}

    def state(counts):
        key = close(counts)
        if key not in ids:
            ids[key] = len(states)
            states.append(key)
            todo.append(ids[key])
        return ids[key]
    starts = {n: state({start if direction == 'left' else entries[n]: 1}) for n in members}
    while todo:
        d = todo.popleft()
        choices = {}
        acc = {}
        for q, w in states[d]:
            if q in finals:
                acc[finals[q]] = w
            for e in out[q]:
                if e[0] != 'A':
                    continue
                _, atom, r = e
                weights = choices.setdefault(atom, collections.defaultdict(int))
                weights[r] = min(2, weights[r] + w)
        accepts[d] = acc
        trans[d] = {atom: state(weights) for atom, weights in choices.items()}
        if len(states) > 100000:
            raise RuntimeError('component DFA limit')
    reverse = collections.defaultdict(set)
    for d, edges in trans.items():
        for t in edges.values():
            reverse[t].add(d)
    for n in members:
        req = n if direction == 'left' else 'end'
        live = {d for d in trans if accepts[d].get(req, 0)}
        todo = list(live)
        while todo:
            for d in reverse[todo.pop()]:
                if d not in live:
                    live.add(d)
                    todo.append(d)
        if not starts[n] in live:
            raise ValueError(n)
        colors = {d: accepts[d].get(req, 0) for d in live}
        while True:
            intern = {}
            newcolors = {}
            for d in sorted(live):
                signature = (colors[d], tuple(sorted(((repr(atom), colors[t]) for atom, t in trans[d].items() if t in live))))
                if signature not in intern:
                    intern[signature] = len(intern)
                newcolors[d] = intern[signature]
            if len(set(colors.values())) == len(intern):
                colors = newcolors
                break
            colors = newcolors
        mt = {}
        ma = {}
        for d in live:
            k = colors[d]
            mt[k] = {atom: colors[t] for atom, t in trans[d].items() if t in live}
            ma[k] = accepts[d].get(req, 0)
        ren = {colors[starts[n]]: 0}
        todo = collections.deque(ren)
        ct = {}
        ca = {}
        while todo:
            d = todo.popleft()
            edges = {}
            for atom, t in sorted(mt[d].items(), key=lambda x: repr(x[0])):
                if t not in ren:
                    ren[t] = len(ren)
                    todo.append(t)
                edges[atom] = ren[t]
            ct[ren[d]] = edges
            ca[ren[d]] = ma[d]
        signature = tuple(((ca[d], tuple(sorted(ct[d].items(), key=lambda x: repr(x[0])))) for d in range(len(ct))))
        if signature not in LIBIDS:
            LIBIDS[signature] = len(LIB)
            LIB.append((0, ct, ca))
        LANG[n] = LIBIDS[signature]
    if len(states) > 1000 or c % 100 == 0:
        print('compiled', c, len(states), 'DFA states', len(nodes), 'NFA states', len(LIB), 'languages', flush=True)
print('horizontal library', len(LIB), 'languages', sum((len(t) for _, t, a in LIB)), 'states; largest', max((len(t) for _, t, a in LIB)), flush=True)

class Model:

    def __init__(self):
        self.nodes = []
        self.ids = {}
        self.out = {}
        self.frags = []
        self.fids = {}
        self.root = self.fragment(('n0',))

    def node(self, key):
        if key not in self.ids:
            self.ids[key] = len(self.nodes)
            self.nodes.append(key)
            if len(self.nodes) > 2000000:
                raise RuntimeError('model state limit')
        return self.ids[key]

    def fragment(self, seq):
        if seq not in self.fids:
            f = len(self.frags)
            self.fids[seq] = f
            self.frags.append(None)
            end = self.node(('end', f))
            entry = self.head(seq, end)
            self.frags[f] = (entry, end)
        return self.fids[seq]

    def language(self, n, tail):
        lid = LANG[n]
        initial, _, _ = LIB[lid]
        return self.node(('component', lid, initial, tail))

    def head(self, seq, tail):
        for x in reversed(seq):
            if isinstance(x, tuple):
                tail = self.node(('call', x[1], self.fragment(x[2]), tail, x[3]))
            elif x not in rules:
                tail = self.node(('internal', x, tail))
            elif x not in nonempty:
                if not EPS[x]:
                    raise ValueError('proof invariant failed')
                if EPS[x] > 1:
                    tail = self.node(('weight', tail, EPS[x]))
            else:
                tail = self.language(x, tail)
        return tail

    def edges(self, q):
        if q in self.out:
            return self.out[q]
        key = self.nodes[q]
        kind = key[0]
        out = []
        if kind == 'end':
            pass
        elif kind == 'weight':
            out = [('E', key[1], key[2])]
        elif kind == 'internal':
            out = [('I', key[1], key[2])]
        elif kind == 'call':
            out = [('C', *key[1:])]
        elif kind == 'component':
            _, lid, d, tail = key
            _, trans, acc = LIB[lid]
            w = acc[d]
            if w:
                out.append(('E', tail, w))
            for atom, nextd in trans[d].items():
                dest = self.node(('component', lid, nextd, tail))
                if atom[0] == 'T':
                    out.append(('I', atom[1], dest))
                else:
                    out.append(('C', atom[1], self.fragment(atom[2]), dest, atom[3]))
        else:
            raise ValueError(key)
        self.out[q] = out
        return out
