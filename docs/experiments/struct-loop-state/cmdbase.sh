#!/bin/sh
# cmdbase.sh BIN : at runArray's dispatch load, the commands array's base and the tape's
B=$1
L=$(objdump -d --no-show-raw-insn "$B" | awk '/runArray.*>:$/{f=1} f&&/^$/{f=0} f' | grep -B1 'add    $0xffffffffffffffd5' | head -1)
A=0x$(echo "$L" | awk '{print $1}' | tr -d :)
R=$(echo "$L" | sed -E 's/.*-0x8\(%([a-z0-9]+),.*/\1/')
T=$(objdump -d --no-show-raw-insn "$B" | awk '/runArray.*>:$/{f=1} f&&/^$/{f=0} f' | grep -m1 'incb   -0x1(' | sed -E 's/.*incb   -0x1\(%([a-z0-9]+),.*/\1/')
cd /home/user/la-zane
gdb -q -batch -ex "handle SIGSEGV nostop noprint pass" -ex "handle SIGBUS nostop noprint pass" -ex "break *$A" -ex "run run.js Brainfuck::Array" -ex "p/x \$$R" -ex "p/x \$$T" -ex "p/x \$pc" "$B" 2>&1 | grep '^\$' | tr '\n' ' '
echo " ($A $R $T)"
