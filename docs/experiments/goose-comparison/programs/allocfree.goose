// N small objects allocated one by one into a list, then released in
// random order, 10 times over. N is the program's first argument. The
// objects come from a reusable pool, whose freelist takes the released
// slots back; the list holds 4-byte links into the pool.

import std;
import os;

struct Item { id: i64, x: f64, y: f64, hp: i64 }

reusable var pool: Item[>..] = [];
var state = 42;

fn below(bound: i64) -> i64 {
    state = (state * 1103515245 + 12345) & 2147483647;
    return state % bound;
}

fn main() {
    let a = args();
    var n = 10000;
    if a.len > 1 { let v, ok = parse_int(a[1]); if ok { n = v; } }
    var items: (Item&<u32 in pool>)[>..<] = [];
    var hash = 0;
    for round in 10 {
        for i in 1..n + 1 {
            items.push(pool.alloc_ref(Item { i, 0.5 * (i as f64), 0.25 * (i as f64), i / 3 }));
        }
        var size = n;
        while size > 0 {
            let k = below(size);
            let slot = pool.index_of(items[k]);
            hash = (hash * 31 + items[k].id) & 2147483647;
            items.swap_remove(k);
            pool.free(slot);
            size--;
        }
    }
    print(n, " ", hash);
}
