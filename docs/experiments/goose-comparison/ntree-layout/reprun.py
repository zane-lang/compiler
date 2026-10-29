#!/usr/bin/env python3
# Runs replay.c's layouts (build it first: clang -O2 replay.c -o replay),
# alternating their order, and prints each one's least grow and count cycles.
#
#   python3 reprun.py 10
import os, subprocess, re, sys
# least grow and count cycles per form, each run of the replay itself the least of 5, 6 alternating passes
forms = [3, 4, 0, 1, 5, 2]; depth = sys.argv[1] if len(sys.argv) > 1 else "10"
best = {}
for i in range(6):
    for f in (forms if i % 2 == 0 else forms[::-1]):
        out = subprocess.run([os.path.join(os.path.dirname(os.path.abspath(__file__)), "replay"), str(f), depth, "5"], capture_output=True, text=True).stdout
        name = out[:20].strip(); g, c = map(float, re.search(r"grow\s+(\d+)M\s+count\s+(\d+)M", out).groups())
        mb = re.search(r"([\d.]+) MB", out).group(1)
        b = best.setdefault(name, [1e18, 1e18, mb]); b[0] = min(b[0], g); b[1] = min(b[1], c)
for n, (g, c, mb) in best.items(): print(f"{n:22} grow {g:4.0f}M  count {c:4.0f}M  {mb} MB")
