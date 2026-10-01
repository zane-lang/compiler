"""Exact weighted determinization over the finite semiring {0,1,many}."""
import sys, time, collections, json
from pathlib import Path
from horizontal import Model
model = Model()
vectors = []
vectorids = {}
frames = []
frameids = {}
queue = collections.deque()
reached = 0
limit = int(sys.argv[2]) if len(sys.argv) > 2 else 100000
seconds = int(sys.argv[3]) if len(sys.argv) > 3 else 300
started = time.monotonic()

def vector(counts):
    closure = {key: min(2, w) for key, w in counts.items() if w}
    pending = collections.deque(closure.items())
    while pending:
        (f, q), delta = pending.popleft()
        for e in model.edges(q):
            if e[0] != 'E':
                continue
            _, target, w = e
            key = (f, target)
            old = closure.get(key, 0)
            new = min(2, old + delta * w)
            if new > old:
                closure[key] = new
                pending.append((key, new - old))
    key = tuple(sorted(((f, q, w) for (f, q), w in closure.items() if model.nodes[q][0] == 'end' or any((e[0] != 'E' for e in model.edges(q))))))
    if key not in vectorids:
        vectorids[key] = len(vectors)
        vectors.append(key)
    return vectorids[key]

def add(fid, v):
    global reached
    fr = frames[fid]
    if v not in fr['nodes']:
        fr['nodes'].add(v)
        queue.append((fid, v))
        reached += 1
        if reached > limit:
            raise RuntimeError('node limit')

def frame(fs, closer):
    key = (tuple(sorted(fs)), closer)
    if key not in frameids:
        fid = len(frames)
        frameids[key] = fid
        frames.append({'key': key, 'nodes': set(), 'exits': set(), 'callers': set()})
        add(fid, vector({(f, model.frags[f][0]): 1 for f in fs}))
    return frameids[key]

def return_vector(context, accepted):
    counts = collections.defaultdict(int)
    a = dict(accepted)
    for pf, cf, ret, w in context:
        counts[pf, ret] = min(2, counts[pf, ret] + w * a.get(cf, 0))
    return vector(counts) if any(counts.values()) else None
root = frame([0], None)
try:
    while queue:
        if time.monotonic() - started > seconds:
            raise RuntimeError('time limit')
        fid, v = queue.popleft()
        fr = frames[fid]
        accepted = collections.defaultdict(int)
        internal = {}
        calls = {}
        for f, q, w in vectors[v]:
            end = model.frags[f][1]
            if q == end:
                accepted[f] = min(2, accepted[f] + w)
            for e in model.edges(q):
                if e[0] == 'I':
                    counts = internal.setdefault(e[1], collections.defaultdict(int))
                    key = (f, e[2])
                    counts[key] = min(2, counts[key] + w)
                elif e[0] == 'C':
                    counts = calls.setdefault(e[1], collections.defaultdict(int))
                    key = (f, e[2], e[3], e[4])
                    counts[key] = min(2, counts[key] + w)
                elif e[0] != 'E':
                    raise ValueError(e)
        accepted = tuple(sorted(((f, w) for f, w in accepted.items() if w)))
        if accepted:
            if fid == root and dict(accepted).get(0, 0) > 1:
                print('AMBIGUOUS', reached, 'nodes', len(frames), 'frames', len(model.nodes), 'states', flush=True)
                sys.exit(1)
            if accepted not in fr['exits']:
                fr['exits'].add(accepted)
                for parent, context in fr['callers']:
                    rv = return_vector(context, accepted)
                    if rv is not None:
                        add(parent, rv)
        for token, counts in internal.items():
            add(fid, vector(counts))
        for token, counts in calls.items():
            closers = {close for pf, cf, ret, close in counts}
            if not len(closers) == 1:
                raise ValueError('proof invariant failed')
            context = tuple(sorted(((pf, cf, ret, w) for (pf, cf, ret, close), w in counts.items())))
            child = frame({cf for pf, cf, ret, w in context}, next(iter(closers)))
            cf = frames[child]
            caller = (fid, context)
            if caller not in cf['callers']:
                cf['callers'].add(caller)
                for accepted in cf['exits']:
                    rv = return_vector(context, accepted)
                    if rv is not None:
                        add(fid, rv)
    if len(sys.argv) > 4:
        import hashlib
        cert = {'schema': 1, 'grammar_sha256': hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest(), 'vectors': vectors, 'frames': [{'key': fr['key'], 'nodes': sorted(fr['nodes']), 'exits': sorted(fr['exits'])} for fr in frames]}
        i = 0
        while i < len(model.nodes):
            model.edges(i)
            i += 1
        cert['model'] = {'fragments': model.frags, 'edges': [model.edges(i) for i in range(len(model.nodes))]}
        Path(sys.argv[4]).write_text(json.dumps(cert, separators=(',', ':')) + '\n')
    print('PROVEN', reached, 'nodes', len(frames), 'frames', len(model.nodes), 'states', round(time.monotonic() - started, 2), 'sec', flush=True)
except (RuntimeError, ValueError, AssertionError) as e:
    print('NOT_PROVEN', str(e), reached, 'nodes', len(frames), 'frames', len(model.nodes), 'states', flush=True)
    sys.exit(2)
