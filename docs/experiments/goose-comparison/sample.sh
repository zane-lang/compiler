#!/bin/bash
# Where a running program spends its time, without hardware counters: gdb
# interrupts it 150 times and each sample's function is counted. Run one
# long enough to outlast the samples, for example binarytrees at depth 22:
#
#   ./sample.sh /tmp/zane-goose-variants/binarytrees.zane-pooled-peel-packed 22
"$@" > /dev/null & pid=$!
sleep 0.3
for i in $(seq 150); do
  gdb -q -batch -p $pid -ex "x/i \$pc" 2>/dev/null | grep "=>" | sed "s/:.*//; s/.*</</; s/+.*//"
  sleep 0.02
done | sort | uniq -c | sort -rn | head -12
kill $pid 2>/dev/null; wait $pid 2>/dev/null
