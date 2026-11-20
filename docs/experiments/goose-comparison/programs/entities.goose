// N entities held inline in one array, scanned 100 times to sum their hit
// points. N is the program's first argument.

import std;
import os;

struct Entity { id: i64, x: f64, y: f64, hp: i64 }

fn main() {
    let a = args();
    var n = 100000;
    if a.len > 1 { let v, ok = parse_int(a[1]); if ok { n = v; } }
    var entities: Entity[>..] = [];
    for i in 1..n + 1 {
        entities.push(Entity { i, 0.5 * (i as f64), 0.25 * (i as f64), i / 3 });
    }
    var total = 0;
    for pass in 100 {
        for e in entities { total += e.hp; }
    }
    print(n, " ", total);
}
