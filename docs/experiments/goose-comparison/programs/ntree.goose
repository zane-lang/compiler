// Trees whose nodes own a growable list of children: a complete four-way
// tree N levels deep, built, counted and torn down 10 times. N is the
// program's first argument. A node's children are links in a list held
// inline in the node, growable up to four; the nodes live in a pool local
// to the round.

import std;
import os;

struct Node { children: (Node&<u32>)[..4] }

recursive fn grow(pool: Node[>..]&, depth: i64) -> Node& {
    let n .= pool.push(Node { .. });
    if depth > 0 {
        for k in 4 { n.children.push(grow(pool, depth - 1)); }
    }
    return n;
}

recursive fn count(n: Node&) -> i64 {
    var total = 1;
    for c in n.children { total += count(c); }
    return total;
}

fn main() {
    let a = args();
    var depth = 6;
    if a.len > 1 { let v, ok = parse_int(a[1]); if ok { depth = v; } }
    var total = 0;
    for round in 10 {
        var pool: Node[>..] = [];
        total += count(grow(pool, depth));
    }
    print(depth, " ", total);
}
