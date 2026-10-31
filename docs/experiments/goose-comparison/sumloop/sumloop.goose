// A loop whose body is one load and one add: a list of N integers summed
// 200000 times, the total written into its first element after each round.
// N is the program's first argument.

import std;
import os;

fn main() {
    let a = args();
    var n = 2000;
    if a.len > 1 { let v, ok = parse_int(a[1]); if ok { n = v; } }
    let rounds = 200000;
    var list: i64[>..] = [];
    for i in 1..n + 1 { list.push(i); }
    var total = 0;
    for r in rounds {
        for k in list.len { total += list[k]; }
        list[0] = total;
    }
    print(n, " ", total);
}
