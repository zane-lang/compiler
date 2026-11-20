// binarytrees with the tree as a fixed-mode enum linked by plain 8-byte
// references: the same pools as binarytrees.goose, a leaf a payload-less
// variant instead of a node with null links.

import std;
import os;

enum Tree { Leaf, Node { left: Tree&, right: Tree& } }

recursive fn make(pool: Tree[>..]&, depth: i64) -> Tree& {
    if depth == 0 { return pool.push(Tree.Leaf); }
    let l: Tree& = make(pool, depth - 1);
    let r: Tree& = make(pool, depth - 1);
    return pool.push(Tree.Node { left: l, right: r });
}

recursive fn check(t: Tree&) -> i64 {
    match t {
        Node n => 1 + check(n.left) + check(n.right),
        _ => 1,
    }
}

fn tree_check(depth: i64) -> i64 {
    var pool: Tree[>..] = [];
    return check(make(pool, depth));
}

fn main() {
    let a = args();
    var n = 10;
    if a.len > 1 { let v, ok = parse_int(a[1]); if ok { n = v; } }
    let max_depth = max(6, n);
    let stretch = max_depth + 1;
    print("stretch ", stretch, " ", tree_check(stretch));
    var long_pool: Tree[>..] = [];
    let long_lived: Tree& = make(long_pool, max_depth);
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
