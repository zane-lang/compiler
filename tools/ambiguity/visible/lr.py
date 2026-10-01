"""Exact LR-action CFG, first/follow partitions; scratch research implementation."""
import collections, re, sys, json
from pathlib import Path
path = Path(sys.argv[1])
output = Path(sys.argv[2])
normalized_symbols = {}
def symbol(raw):
    cleaned = re.sub(r'[^A-Za-z_0-9]', '_', raw)
    previous = normalized_symbols.setdefault(cleaned, raw)
    if previous != raw:
        raise ValueError(('nonterminal normalization collision', previous, raw))
    return cleaned

states = []
prodids = {}
prods = []
look = []
for line in path.read_text().splitlines():
    m = re.fullmatch('State (\\d+):', line)
    if m:
        if not int(m[1]) == len(states):
            raise ValueError('proof invariant failed')
        states.append({'trans': {}, 'red': collections.defaultdict(set), 'accept': set()})
        look = []
        continue
    if not states:
        continue
    s = states[-1]
    m = re.fullmatch('-- On (\\S+) shift to state (\\d+)', line)
    if m:
        s['trans'][symbol(m[1])] = int(m[2])
        continue
    if line.startswith("-- On ") and "shift to state" in line:
        raise ValueError("unrecognized transition format")
    m = re.fullmatch('-- On (.+)', line)
    if m:
        look = m[1].split()
        continue
    m = re.fullmatch('--   reduce production (.+) ->(.*)', line)
    if m:
        p = (symbol(m[1]), tuple(symbol(x) for x in m[2].split()))
        if p not in prodids:
            prodids[p] = len(prods)
            prods.append(p)
        s['red'][prodids[p]].update(look)
    if line.startswith('--   reduce production') and not m:
        raise ValueError('unrecognized reduction format')
    if line.startswith('--   accept'):
        s['accept'].update(look)
expanded = Path(sys.argv[3])
text = expanded.read_text()
shapes = []
lhs = None
pending = []
for line in text.split('%%')[1].splitlines():
    stripped = line.strip()
    if re.fullmatch('[A-Za-z_][A-Za-z_0-9]*:', stripped):
        if pending:
            raise ValueError('unfinished source production')
        lhs = stripped[:-1]
        continue
    if lhs is None:
        continue
    if stripped.startswith('|'):
        stripped = stripped[1:].strip()
    if '{}' in stripped:
        pending.append(stripped.split('{}', 1)[0])
        tokens = ' '.join(pending).split()
        if '%prec' in tokens:
            i = tokens.index('%prec')
            del tokens[i:i + 2]
        shapes.append((lhs, tuple(tokens)))
        pending = []
    elif stripped:
        pending.append(stripped)
if pending:
    raise ValueError('unfinished source production')
if len(shapes) != len(set(shapes)):
    raise ValueError('duplicate source production shapes cannot be identified in a text dump')
if set(prods) != set(shapes):
    raise ValueError('dump productions differ from the expanded grammar')
if not states or states[0]['trans'].get('package') is None:
    raise ValueError('missing package start transition')
if states[states[0]['trans']['package']]['accept'] != {'#'}:
    raise ValueError('package goto is not the unique end-of-input acceptance')
nts = {lhs for lhs, rhs in prods}
rev = collections.defaultdict(set)
for q, s in enumerate(states):
    for x, r in s['trans'].items():
        rev[r, x].add(q)
occ = []
bynt = collections.defaultdict(list)
for end, s in enumerate(states):
    for p, follow in s['red'].items():
        lhs, rhs = prods[p]
        bases = {end}
        for x in reversed(rhs):
            bases = {q for r in bases for q in rev[r, x]}
        for q in bases:
            if lhs not in states[q]['trans']:
                continue
            route = [q]
            for x in rhs:
                route.append(states[route[-1]]['trans'][x])
            k = len(occ)
            occ.append((p, route, follow))
            bynt[q, lhs].append(k)
print('states', len(states), 'productions', len(prods), 'occurrences', len(occ), flush=True)
if True:
    names = {}
    todo = collections.deque()
    rules = {}
    guards = []
    labelled = {}

    def cname(q, x):
        key = (q, x)
        if key not in names:
            names[key] = 'n' + str(len(names))
            todo.append(key)
        return names[key]
    cname(0, 'package')
    while todo:
        q, x = todo.popleft()
        rs = []
        ls = []
        for k in bynt[q, x]:
            p, route, follow = occ[k]
            lhs, rhs = prods[p]
            r = tuple((cname(route[i], y) if y in nts else y for i, y in enumerate(rhs)))
            rs.append(r)
            guards.append((names[q, x] + ' -> ' + ' '.join(r), ' '.join(('$' if t == '#' else t for t in sorted(follow)))))
            ls.append((p, r, tuple(sorted(follow))))
        rules[names[q, x]] = rs
        labelled[names[q, x]] = ls
    productive = set()
    while True:
        previous = len(productive)
        for n, rs in rules.items():
            if any((all((x not in rules or x in productive for x in r)) for r in rs)):
                productive.add(n)
        if len(productive) == previous:
            break
    if "n0" not in productive:
        raise ValueError("start grammar is unproductive")
    for n in list(labelled):
        labelled[n] = [rule for rule in labelled[n] if all((x not in rules or x in productive for x in rule[1]))]
    reachable = {'n0'}
    queue = collections.deque(reachable)
    while queue:
        n = queue.popleft()
        for p, r, follow in labelled[n]:
            for x in r:
                if x in rules and x not in reachable:
                    reachable.add(x)
                    queue.append(x)
    labelled = {n: ls for n, ls in labelled.items() if n in reachable}
    rules = {n: [r for p, r, follow in ls] for n, ls in labelled.items()}
    guards = [(n + ' -> ' + ' '.join(r), ' '.join(('$' if t == '#' else t for t in follow))) for n, ls in labelled.items() for p, r, follow in ls]
    if '--minimize' in sys.argv:
        colors = {n: x for (q, x), n in names.items() if n in labelled}
        while True:
            intern = {}
            new = {}
            for n, ls in labelled.items():
                signature = (colors[n], tuple(sorted(((p, tuple((('nt', colors[x]) if x in colors else ('term', x) for x in r)), follow) for p, r, follow in ls))))
                if signature not in intern:
                    intern[signature] = len(intern)
                new[n] = intern[signature]
            print('bisimulation classes', len(intern), flush=True)
            if len(set(colors.values())) == len(intern):
                colors = new
                break
            colors = new
        groups = collections.defaultdict(list)
        for n, c in colors.items():
            groups[c].append(n)
        rename = {c: 'n' + str(i) for i, c in enumerate([colors['n0']] + [c for c in groups if c != colors['n0']])}
        minimized = {}
        guards = []
        for c, group in groups.items():
            n = rename[c]
            rs = []
            for p, r, follow in labelled[group[0]]:
                r = tuple((rename[colors[x]] if x in colors else x for x in r))
                rs.append(r)
                guards.append((n + ' -> ' + ' '.join(r), ' '.join(('$' if t == '#' else t for t in follow))))
            if not len(set(rs)) == len(rs):
                raise ValueError((n, rs))
            minimized[n] = rs
        rules = minimized
    terms = sorted({x for rs in rules.values() for r in rs for x in r if x not in rules})
    with output.open('w') as stream:
        stream.write('%token ' + ' '.join(terms) + '\n%start n0\n%%\n')
        for n, rs in rules.items():
            stream.write(n + ' : ' + ' | '.join((' '.join(r) for r in rs)) + ' ;\n')
    output.with_suffix('.guards.tsv').write_text('\n'.join((k + '\t' + v for k, v in guards)))
    output.with_suffix('.context.json').write_text(json.dumps({'source_productions': len(shapes), 'retained_productions': len(prods), 'states': len(states)}))
    print('context export', len(rules), 'nts', len(guards), 'rules', flush=True)
