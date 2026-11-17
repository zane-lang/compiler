import sys,statistics,collections
d=collections.OrderedDict()
for l in sys.stdin:
    *_,b,v=l.split(); d.setdefault(b,[]).append(float(v))
for b,v in d.items(): print(f"{b.split('/')[-1]:14s} median {statistics.median(v):.3f} min {min(v):.3f} n={len(v)}")
