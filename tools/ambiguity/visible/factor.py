from pathlib import Path
import collections, sys
src = Path(sys.argv[1])
out = Path(sys.argv[2])
rules = {}
for line in src.read_text().splitlines()[3:]:
    n, r = line.split(' : ')
    rules[n] = [tuple(x.split()) for x in r.removesuffix(' ;').split(' | ')]
for iteration in range(8):
    nonempty = set()
    while True:
        old = len(nonempty)
        for n, rs in rules.items():
            if any((any((x not in rules or x in nonempty for x in r)) for r in rs)):
                nonempty.add(n)
        if len(nonempty) == old:
            break
    eps = {n: 0 for n in rules}
    while True:
        new = {}
        for n, rs in rules.items():
            count = 0
            for r in rs:
                w = 1
                for x in r:
                    w = min(2, w * eps.get(x, 0))
                count = min(2, count + w)
            new[n] = count
        if new == eps:
            break
        eps = new
    pure = {n for n in rules if n not in nonempty and eps[n] == 1}
    rules = {n: [tuple((x for x in r if x not in pure)) for r in rs] for n, rs in rules.items() if n not in pure or n == 'n0'}
    aliases = {n: rs[0][0] for n, rs in rules.items() if n != 'n0' and len(rs) == 1 and (len(rs[0]) == 1) and (rs[0][0] in rules)}

    def resolve(n):
        seen = set()
        while n in aliases:
            if not n not in seen:
                raise ValueError('proof invariant failed')
            seen.add(n)
            n = aliases[n]
        return n
    rules = {n: [tuple((resolve(x) for x in r)) for r in rs] for n, rs in rules.items() if n not in aliases}
    intern = {tuple(sorted(rs)): n for n, rs in rules.items()}
    extra = {}
    newrules = {}
    for n, rs in rules.items():
        buckets = collections.defaultdict(list)
        for r in rs:
            buckets[r[0] if r else None].append(r)
        nr = []
        for x, group in buckets.items():
            if x is None or len(group) == 1 or all((len(r) == 1 for r in group)):
                nr.extend(group)
                continue
            tails = tuple(sorted((r[1:] for r in group)))
            if tails not in intern:
                name = 'g' + str(iteration) + 'x' + str(len(extra))
                intern[tails] = name
                extra[name] = list(tails)
            nr.append((x, intern[tails]))
        newrules[n] = nr
    newrules.update(extra)
    rules = newrules
    colors = {n: 0 for n in rules}
    while True:
        signatures = {}
        new = {}
        for n, rs in rules.items():
            key = (colors[n], tuple(sorted((tuple((('N', colors[x]) if x in rules else ('T', x) for x in r)) for r in rs))))
            if key not in signatures:
                signatures[key] = len(signatures)
            new[n] = signatures[key]
        if len(set(colors.values())) == len(signatures):
            colors = new
            break
        colors = new
    representatives = {}
    for n, c in colors.items():
        representatives.setdefault(c, n)
    representatives[colors['n0']] = 'n0'
    rules = {representatives[colors[n]]: [tuple((representatives[colors[x]] if x in rules else x for x in r)) for r in rs] for n, rs in rules.items()}
    print(iteration, len(rules), sum(map(len, rules.values())), flush=True)
terms = sorted({x for rs in rules.values() for r in rs for x in r if x not in rules})
out.write_text('%token ' + ' '.join(terms) + '\n%start n0\n%%\n' + '\n'.join((n + ' : ' + ' | '.join((' '.join(r) for r in rs)) + ' ;' for n, rs in rules.items())) + '\n')
