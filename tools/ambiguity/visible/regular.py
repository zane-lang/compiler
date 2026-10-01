from pathlib import Path
import sys, collections, json
source = Path(sys.argv[1])
rules = {}
for line in source.read_text().splitlines()[3:]:
    lhs, rhs = line.split(' : ')
    rules[lhs] = [tuple(r.split()) for r in rhs.removesuffix(' ;').split(' | ')]
opens = {'LPAREN': 'RPAREN', 'LCURLY': 'RCURLY', 'LBRACKET': 'RBRACKET', 'GLESS': 'GMORE'}

def outer(r):
    out = []
    stack = []
    for x in r:
        if x in opens:
            if not stack:
                out.append('balanced-group')
            stack.append(opens[x])
        elif x in opens.values():
            if not (stack and x == stack.pop()):
                raise ValueError(r)
        elif not stack:
            out.append(x)
    if not not stack:
        raise ValueError(r)
    return tuple(out)
flat = {n: [outer(r) for r in rs] for n, rs in rules.items()}
graph = {n: set() for n in rules}
reverse = {n: set() for n in rules}
for n, rs in flat.items():
    for r in rs:
        for x in r:
            if x in rules:
                graph[n].add(x)
                reverse[x].add(n)
visited = set()
order = []
for n in graph:
    if n in visited:
        continue
    visited.add(n)
    stack = [(n, iter(graph[n]))]
    while stack:
        parent, children = stack[-1]
        child = next(children, None)
        if child is None:
            order.append(parent)
            stack.pop()
        elif child not in visited:
            visited.add(child)
            stack.append((child, iter(graph[child])))
components = []
visited = set()
for n in reversed(order):
    if n in visited:
        continue
    visited.add(n)
    component = {n}
    todo = [n]
    while todo:
        for x in reverse[todo.pop()]:
            if x not in visited:
                visited.add(x)
                component.add(x)
                todo.append(x)
    components.append(component)
of = {n: i for i, s in enumerate(components) for n in s}
nonempty = set()
while True:
    prior = len(nonempty)
    for n, rs in flat.items():
        if any((any((x not in rules or x in nonempty for x in r)) for r in rs)):
            nonempty.add(n)
    if prior == len(nonempty):
        break
bad = []
orientations = collections.defaultdict(set)
for n, rs in flat.items():
    c = of[n]
    for r in rs:
        same = [i for i, x in enumerate(r) if x in of and of[x] == c]
        if len(same) > 1:
            bad.append(('nonlinear', n, r))
            continue
        if not same:
            continue
        i = same[0]
        before = any((x not in rules or x in nonempty for x in r[:i]))
        after = any((x not in rules or x in nonempty for x in r[i + 1:]))
        if before:
            orientations[c].add('right')
        if after:
            orientations[c].add('left')
        if before and after:
            bad.append(('two-sided', n, r))
for c, ds in orientations.items():
    if len(ds) > 1:
        bad.append(('mixed-orientation', sorted(components[c])[:10]))
print('components', len(components), 'non-regular obligations', len(bad))
for entry in bad[:50]:
    print(json.dumps(entry))
print('largest component', max(map(len, components)))
EPS = {n: 0 for n in rules}

def product(xs):
    v = 1
    for x in xs:
        v = min(2, v * x)
    return v
while True:
    new = {n: min(2, sum((product((EPS[x] if x in rules else 0 for x in r)) for r in rs))) for n, rs in rules.items()}
    if new == EPS:
        break
    EPS = new

def chunks(r):
    out = []
    i = 0
    while i < len(r):
        x = r[i]
        if x not in opens:
            out.append(x)
            i += 1
            continue
        pending = [opens[x]]
        j = i + 1
        while pending:
            y = r[j]
            if y in opens:
                pending.append(opens[y])
            elif y in opens.values():
                if not pending.pop() == y:
                    raise ValueError('proof invariant failed')
            j += 1
        out.append(('call', x, chunks(r[i + 1:j - 1]), opens[x]))
        i = j
    return tuple(out)
normalized = {n: [chunks(r) for r in rs] for n, rs in rules.items()}
directions = {c: 'left' if orientations[c] == {'left'} else 'right' for c in range(len(components))}
