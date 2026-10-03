"""Certify a unique angular-delimiter annotation of the accepted token strings."""
from pathlib import Path
import collections, json, sys
source = Path(sys.argv[1])
output = Path(sys.argv[2])
rules = {}
for line in source.read_text().splitlines()[3:]:
    lhs, rest = line.split(' : ')
    rules[lhs] = [tuple(r.split()) for r in rest.removesuffix(' ;').split(' | ')]
guards = {}
for line in source.with_suffix('.guards.tsv').read_text().splitlines():
    key, ts = line.split('\t')
    guards[key.strip()] = ts.split()
tagged = {}
newguards = {}
regions = []
for n, rs in rules.items():
    tagged[n] = []
    for r in rs:
        if 'LESS' in r and 'MORE' in r:
            if not (r.count('LESS') == r.count('MORE') == 1 and r.index('LESS') < r.index('MORE')):
                raise ValueError(r)
            regions.append(r[r.index('LESS') + 1:r.index('MORE')])
            s = tuple(({'LESS': 'GLESS', 'MORE': 'GMORE'}.get(x, x) for x in r))
        else:
            s = r
        tagged[n].append(s)
        tokens = set(guards[(n + ' -> ' + ' '.join(r)).strip()])
        if 'LESS' in tokens:
            tokens.add('GLESS')
        if 'MORE' in tokens:
            tokens.add('GMORE')
        newguards[(n + ' -> ' + ' '.join(s)).strip()] = sorted(tokens)
rules = tagged
EPS = 'epsilon'
first = {n: set() for n in rules}
last = {n: set() for n in rules}

def endseq(r, table):
    result = set()
    for x in r:
        part = table[x] if x in rules else {x}
        result.update(part - {EPS})
        if EPS not in part:
            return result
    result.add(EPS)
    return result
while True:
    changed = False
    for n, rs in rules.items():
        for r in rs:
            for table, seq in [(first, r), (last, tuple(reversed(r)))]:
                new = endseq(seq, table) - table[n]
                if new:
                    table[n].update(new)
                    changed = True
    if not changed:
        break
prev = {n: set() for n in rules}
after = {n: set() for n in rules}
prev['n0'].add('START')
after['n0'].add('END')
while True:
    changed = False
    for n, rs in rules.items():
        for r in rs:
            for i, x in enumerate(r):
                if x not in rules:
                    continue
                for table, part, ends in [(prev, endseq(tuple(reversed(r[:i])), last), prev[n]), (after, endseq(r[i + 1:], first), after[n])]:
                    new = part - {EPS} | (ends if EPS in part else set())
                    new -= table[x]
                    if new:
                        table[x].update(new)
                        changed = True
    if not changed:
        break
certificate = []
for n, rs in rules.items():
    for r in rs:
        for i, x in enumerate(r):
            if x not in {'LESS', 'GLESS'}:
                continue
            p = endseq(tuple(reversed(r[:i])), last)
            p = p - {EPS} | (prev[n] if EPS in p else set())
            f = endseq(r[i + 1:], first)
            f = f - {EPS} | (after[n] if EPS in f else set())
            if x == 'GLESS':
                if not p == {'UIDENT'}:
                    raise ValueError(('generic predecessor', n, r, p))
                if not 'LPAREN' not in f:
                    raise ValueError(('generic successor', n, r, f))
            elif not ('UIDENT' not in p or f <= {'LPAREN'}):
                raise ValueError(('operator could look generic', n, r, p, f))
            certificate.append({'lhs': n, 'rhs': r, 'index': i, 'previous': sorted(p), 'following': sorted(f)})
inner = set((x for r in regions for x in r if x in rules))
queue = collections.deque(inner)
for r in regions:
    if not ('LESS' not in r and 'MORE' not in r):
        raise ValueError(r)
while queue:
    n = queue.popleft()
    for r in rules[n]:
        if not ('LESS' not in r and 'MORE' not in r):
            raise ValueError(('operator inside generics', n, r))
        for x in r:
            if x in rules and x not in inner:
                inner.add(x)
                queue.append(x)
terms = sorted({x for rs in rules.values() for r in rs for x in r if x not in rules})
with output.open('w') as stream:
    stream.write('%token ' + ' '.join(terms) + '\n%start n0\n%%\n')
    for n, rs in rules.items():
        stream.write(n + ' : ' + ' | '.join((' '.join(r) for r in rs)) + ' ;\n')
output.with_suffix('.guards.tsv').write_text('\n'.join((k + '\t' + ' '.join(ts) for k, ts in newguards.items())))
output.with_suffix('.angle-certificate.json').write_text(json.dumps({'checks': certificate, 'generic_interior_nonterminals': sorted(inner)}, indent=2))
print('Unique annotation certified:', len(certificate), 'opening occurrences;', len(inner), 'generic-interior nonterminals')
