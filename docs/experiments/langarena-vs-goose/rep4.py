# rep4.py TRI.json : min-of-rounds table, Zane against Goose-clang, Goose-gcc and C.
import sys, json, math
t = json.load(open(sys.argv[1])); K = ['Zane', 'Goose-clang', 'Goose-gcc', 'C']
rows = []
for n in t['Zane']:
    v = [t[k].get(n) for k in K]
    if any(x is None or None in x for x in v): print(f'{n}: ERR'); continue
    m = [min(x) for x in v]; rows.append((m[0]/m[1], m[0]/m[2], m[0]/m[3], n, *m))
rows.sort(reverse=True)
print('| Test | Zane (s) | Goose-clang (s) | Goose-gcc (s) | C (s) | Zane / clang | Zane / gcc | Zane / C |')
print('| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |')
for a, b, c, n, z, gc, gg, cc in rows:
    print(f'| {n} | {z:.3f} | {gc:.3f} | {gg:.3f} | {cc:.3f} | {a:.2f} | {b:.2f} | {c:.2f} |')
g = lambda i: math.exp(sum(math.log(r[i]) for r in rows) / len(rows))
f = lambda i: sum(r[i] < 1 for r in rows)
print(f'\ngeomean Zane / Goose-clang {g(0):.3f} (faster on {f(0)}), Zane / Goose-gcc {g(1):.3f} '
      f'(faster on {f(1)}), Zane / C {g(2):.3f} (faster on {f(2)}), {len(rows)} tests')
