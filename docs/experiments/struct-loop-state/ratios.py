"""ratios.py CSV BASE OTHER... : per binary group, median paired ratio of OTHER over BASE"""
import csv,statistics,sys
from collections import defaultdict
t=defaultdict(dict)
for r,n,s in csv.reader(open(sys.argv[1])):
    if s!="FAIL": t[n][int(r)]=float(s)
def q(xs,f):
    xs=sorted(xs); return xs[min(len(xs)-1,int(f*(len(xs)-1)+.5))]
def ratio(a,b):
    rs=[t[a][r]/t[b][r] for r in t[a] if r in t[b]]
    return f"{statistics.median(rs):.3f} [{q(rs,.25):.3f}, {q(rs,.75):.3f}]"
pairs=[a.split("=") for a in sys.argv[2:]]
for label,(a,b) in [(p[0],p[1].split("/")) for p in pairs]:
    print(f"{label:28s} {ratio(a,b)}  (n={len(t[a])}, {a} median {statistics.median(t[a].values()):.3f}s)")
