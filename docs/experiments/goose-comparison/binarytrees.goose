// The Benchmarks Game's binary-trees: perfect binary trees built, walked
// and torn down, many small ones and one that lives through the run. Each
// tree is a pool local to the function that builds it, linked by 4-byte
// self-relative references, and freed when that function returns.

import std;
import os;

struct Node { left: Node&<u32>?, right: Node&<u32>? }

recursive fn make(pool: Node[>..]&, depth: i64) -> Node& {
    if depth == 0 { return pool.push(Node {}); }
    let l: Node& = make(pool, depth - 1);
    let r: Node& = make(pool, depth - 1);
    return pool.push(Node { left: l, right: r });
}

recursive fn check(n: Node&) -> i64 {
    let l = n.left;
    guard l else { return 1; }
    let r = n.right;
    guard r else { return 1; }
    return 1 + check(l) + check(r);
}

fn tree_check(depth: i64) -> i64 {
    var pool: Node[>..] = [];
    return check(make(pool, depth));
}

fn main() {
    let a = args();
    var n = 10;
    if a.len > 1 { let v, ok = parse_int(a[1]); if ok { n = v; } }
    let max_depth = max(6, n);
    let stretch = max_depth + 1;
    print("stretch ", stretch, " ", tree_check(stretch));
    var long_pool: Node[>..] = [];
    let long_lived: Node& = make(long_pool, max_depth);
    var depth = 4;
    while depth <= max_depth {
        let iterations = 1 << (max_depth - depth + 4);
        var total = 0;
        for i in iterations { total += tree_check(depth); }
        print(iterations, " ", depth, " ", total);
        depth += 2;
    }
    print("long ", max_depth, " ", check(long_lived));
}
