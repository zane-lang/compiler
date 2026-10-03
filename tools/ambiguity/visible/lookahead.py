"""Remove local one-token reduction guards by an exact CFG product."""
import collections, functools, json, sys
from pathlib import Path
source = Path(sys.argv[1])
output = Path(sys.argv[2])
EPS = 'epsilon'
rules = {}
for line in source.read_text().splitlines()[3:]:
    lhs, rest = line.split(' : ')
    rules[lhs] = [tuple(r.split()) for r in rest.removesuffix(' ;').split(' | ')]
guards = {}
for line in source.with_suffix('.guards.tsv').read_text().splitlines():
    key, tokens = line.split('\t')
    guards[key.strip()] = tokens.split()
wrapped = set()
if '--bracket-groups' in sys.argv:
    opens = {'LPAREN': 'RPAREN', 'LBRACKET': 'RBRACKET', 'LCURLY': 'RCURLY', 'GLESS': 'GMORE'}
    all_follow = sorted({t for tokens in guards.values() for t in tokens} | {x for rs in rules.values() for r in rs for x in r if x not in rules} | {'$'})
    chunks = {}
    extra = {}

    def group(rhs):
        result = []
        i = 0
        while i < len(rhs):
            x = rhs[i]
            if x not in opens:
                if not x not in opens.values():
                    raise ValueError(('unmatched close', rhs))
                result.append(x)
                i += 1
                continue
            stack = [opens[x]]
            j = i + 1
            while stack:
                y = rhs[j]
                if y in opens:
                    stack.append(opens[y])
                elif y in opens.values():
                    if not y == stack.pop():
                        raise ValueError(rhs)
                j += 1
            inner = group(rhs[i + 1:j - 1])
            signature = (x, inner, opens[x])
            if signature not in chunks:
                n = 'b' + str(len(chunks))
                chunks[signature] = n
                wrapped.add(n)
                if inner:
                    inside = n + 'inner'
                    extra[inside] = [inner]
                    extra[n] = [(x, inside, opens[x])]
                else:
                    extra[n] = [(x, opens[x])]
            result.append(chunks[signature])
            i = j
        return tuple(result)
    modified = {}
    newguards = {}
    for n, rs in list(rules.items()):
        modified[n] = []
        for r in rs:
            changed = group(r)
            modified[n].append(changed)
            newguards[(n + ' -> ' + ' '.join(changed)).strip()] = guards[(n + ' -> ' + ' '.join(r)).strip()]
    for n, rs in extra.items():
        modified[n] = rs
        for r in rs:
            newguards[(n + ' -> ' + ' '.join(r)).strip()] = all_follow
    rules = modified
    guards = newguards
    print('bracket groups', len(chunks), flush=True)
prods = []
bynt = collections.defaultdict(list)
for n, rs in rules.items():
    for r in rs:
        k = len(prods)
        prods.append((n, r, guards[(n + ' -> ' + ' '.join(r)).strip()]))
        bynt[n].append(k)
first = collections.defaultdict(set)

def sf(k, t):
    n, r, follow = prods[k]
    result = {EPS}
    for i in range(len(r) - 1, -1, -1):
        x = r[i]
        if x not in rules:
            result = {x} if result else set()
        else:
            result = {f if a == EPS else a for f in result for a in first[x, t if f == EPS else f]}
    return result
for iteration in range(1000):
    added = 0
    for k, (n, r, follow) in enumerate(prods):
        for t in follow:
            fs = sf(k, t)
            old = len(first[n, t])
            first[n, t].update(fs)
            added += len(first[n, t]) - old
    print('FIRST', iteration, added, flush=True)
    if not added:
        break
else:
    raise RuntimeError('no fixed point')

@functools.lru_cache(None)
def suffix(k, i, t):
    n, r, follow = prods[k]
    if i == len(r):
        return frozenset({EPS})
    x = r[i]
    rest = suffix(k, i + 1, t)
    if x not in rules:
        return frozenset({x}) if rest else frozenset()
    return frozenset((f if a == EPS else a for f in rest for a in first[x, t if f == EPS else f]))
names = {}
queue = collections.deque()
out = {}
labels = {}

def name(key):
    if key not in names:
        names[key] = 'n' + str(len(names))
        queue.append(key)
    return names[key]
name(('start',))
while queue:
    key = queue.popleft()
    rs = []
    ls = []
    if key[0] == 'start':
        rs = [(name(('plain', 'n0', '$')),)]
    elif key[0] in {'nt', 'plain'}:
        if key[0] == 'nt':
            _, x, f, t = key
        else:
            _, x, t = key
            f = None
        for k in bynt[x]:
            if t not in prods[k][2] or not suffix(k, 0, t) or (f is not None and f not in suffix(k, 0, t)):
                continue
            if x in wrapped:
                n, r, follow = prods[k]
                if len(r) == 2:
                    rs.append(r)
                else:
                    rs.append((r[0], name(('plain', r[1], r[2])), r[2]))
            else:
                rs.append((name(('seq', k, 0, f, t)),))
    else:
        _, k, i, f, t = key
        n, r, follow = prods[k]
        if i == len(r):
            if not f in {None, EPS}:
                raise ValueError('proof invariant failed')
            rs = [()]
        else:
            x = r[i]
            if x not in rules:
                if f is None or f == x:
                    rs.append((x, name(('seq', k, i + 1, None, t))))
            else:
                for a in sorted(suffix(k, i + 1, t)):
                    after = t if a == EPS else a
                    rest = ('seq', k, i + 1, a, t)
                    child = first[x, after]
                    if f is None:
                        if child:
                            rs.append((name(('plain', x, after)), name(rest)))
                    else:
                        if f != EPS and f in child:
                            rs.append((name(('nt', x, f, after)), name(rest)))
                        if EPS in child and f == a:
                            rs.append((name(('nt', x, EPS, after)), name(rest)))
    ls = ['rule'] * len(rs)
    if not rs:
        raise ValueError(key)
    out[names[key]] = rs
    labels[names[key]] = ls
    if len(out) % 100000 == 0:
        print('expanded', len(out), 'queued', len(queue), flush=True)
print('expanded', len(out), 'nonterminals', sum(map(len, out.values())), 'rules', flush=True)
colors = {n: 0 for n in out}
while True:
    intern = {}
    new = {}
    for n, rs in out.items():
        signature = (colors[n], tuple(sorted((tuple((('n', colors[x]) if x in colors else ('t', x) for x in r)) for r in rs))))
        if signature not in intern:
            intern[signature] = len(intern)
        new[n] = intern[signature]
    print('partition', len(intern), flush=True)
    if len(set(colors.values())) == len(intern):
        colors = new
        break
    colors = new
groups = collections.defaultdict(list)
for n, c in colors.items():
    groups[c].append(n)
order = [colors['n0']] + [c for c in groups if c != colors['n0']]
rename = {c: 'n' + str(i) for i, c in enumerate(order)}
result = {}
for c, group in groups.items():
    result[rename[c]] = [tuple((rename[colors[x]] if x in colors else x for x in r)) for r in out[group[0]]]
aliases = {n: rs[0][0] for n, rs in result.items() if len(rs) == 1 and len(rs[0]) == 1 and (rs[0][0] in result) and (n != 'n0')}

def resolve(n):
    seen = set()
    while n in aliases:
        if n in seen:
            raise RuntimeError('unit cycle')
        seen.add(n)
        n = aliases[n]
    return n
result = {n: [tuple((resolve(x) for x in r)) for r in rs] for n, rs in result.items() if n not in aliases}
terms = sorted({x for rs in result.values() for r in rs for x in r if x not in result})
with output.open('w') as stream:
    stream.write('%token ' + ' '.join(terms) + '\n%start n0\n%%\n')
    for n, rs in result.items():
        stream.write(n + ' : ' + ' | '.join((' '.join(r) for r in rs)) + ' ;\n')
print('final', len(result), 'nonterminals', sum(map(len, result.values())), 'rules', flush=True)
