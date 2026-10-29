// A growable list of entities, filled by appending N items one at a time,
// built and dropped 20 times. N is the program's first argument.

import std;
import os;

struct Entity { id: i64, x: f64, y: f64, hp: i64 }

fn main() {
    let a = args();
    var n = 100000;
    if a.len > 1 { let v, ok = parse_int(a[1]); if ok { n = v; } }
    var total = 0;
    for round in 20 {
        var list: Entity[>..] = [];
        for i in 1..n + 1 {
            list.push(Entity { i, 0.5 * (i as f64), 0.25 * (i as f64), i / 3 });
        }
        total += list[list.len - 1].hp + list.len;
    }
    print(n, " ", total);
}
