"""The hottest instruction addresses of one function in a Callgrind profile
made with --dump-instr=yes: python3 hot.py PROFILE FUNCTION [N]."""
import collections, re, sys

profile, function = sys.argv[1], sys.argv[2]
top = int(sys.argv[3]) if len(sys.argv) > 3 else 40
counts = collections.Counter()
names, inside, addr, skip = {}, False, 0, False
for line in open(profile):
    line = line.rstrip("\n")
    m = re.match(r"^fn=\((\d+)\)(?: (.*))?$", line)
    if m:
        if m.group(2):
            names[m.group(1)] = m.group(2)
        inside = function in names.get(m.group(1), "")
        continue
    m = re.match(r"^cfn=\((\d+)\) (.*)$", line)
    if m:
        names[m.group(1)] = m.group(2)
        continue
    if line.startswith(("cfn=", "cfi=", "cob=")):
        continue
    if line.startswith("calls="):
        skip = True
        continue
    # Each cost line is an instruction's position, its source line's, and its
    # count (positions: instr line).
    m = re.match(r"^(0x[0-9a-f]+|[+-]\d+|\*)\s+(?:[+-]?\d+|\*)\s+(\d+)", line)
    if not m:
        continue
    pos = m.group(1)
    if pos.startswith("0x"):
        addr = int(pos, 16)
    elif pos != "*":
        addr += int(pos)
    if skip:
        skip = False
        continue
    if inside:
        counts[addr] += int(m.group(2))
for a, c in sorted(counts.most_common(top)):
    print(f"{a:#x} {c}")
print("total", sum(counts.values()))
