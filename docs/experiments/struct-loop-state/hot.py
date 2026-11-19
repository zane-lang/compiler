import re,sys,subprocess,collections
cg,binary=sys.argv[1],sys.argv[2]; FN=sys.argv[3] if len(sys.argv)>3 else "runRecursive"
counts=collections.Counter(); infn=False; last=0; names={}; skip=False
pos_re=re.compile(r"^(0x[0-9a-f]+|[+-]\d+|\*)\s+\S+\s+(\d+)")
for line in open(cg):
    if line.startswith(("fn=","cfn=")):
        m=re.match(r"c?fn=\((\d+)\)\s*(.*)",line)
        if m and m.group(2): names[m.group(1)]=m.group(2)
        if line.startswith("fn="): infn=FN in names.get(m.group(1),"")
        continue
    if line.startswith("calls="):
        m=pos_re.match(line[6:]) ; skip=True
        continue
    m=pos_re.match(line)
    if m:
        p=m.group(1)
        if p.startswith("0x"): a=int(p,16)
        elif p=="*": a=last
        else: a=last+int(p)
        last=a
        if skip: skip=False; continue
        if infn: counts[a]+=int(m.group(2))
tot=sum(counts.values())
dis=subprocess.run(["objdump","-d","--no-show-raw-insn",binary],capture_output=True,text=True).stdout
ins={}
for l in dis.split("\n"):
    m=re.match(r"^\s*([0-9a-f]+):\s+(.*)$",l)
    if m: ins[int(m.group(1),16)]=m.group(2)
hot=[a for a in sorted(counts) if counts[a]>tot*0.002]
print("total", tot, "instrs executed", len(counts), "hot", len(hot))
for a in hot: print(f"{a:x} {counts[a]:>12} {ins.get(a,'?')}")
