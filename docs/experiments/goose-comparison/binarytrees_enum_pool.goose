// binarytrees with the tree as a fixed-mode enum linked by 4-byte
// pool-relative references. A pool-relative link names a global pool in its
// type, so the long-lived tree and the short-lived ones are two enums over
// two global pools, and each short-lived tree is dropped by emptying its
// pool.

import std;
import os;

var long_pool: Long[>..] = [];
var scratch: Tree[>..] = [];

enum Long { Leaf, Node { left: Long&<u32 in long_pool>, right: Long&<u32 in long_pool> } }
enum Tree { Leaf, Node { left: Tree&<u32 in scratch>, right: Tree&<u32 in scratch> } }

recursive fn make_long(depth: i64) -> Long& {
    if depth == 0 { return long_pool.push(Long.Leaf); }
    let l: Long& = make_long(depth - 1);
    let r: Long& = make_long(depth - 1);
    return long_pool.push(Long.Node { left: l, right: r });
}

recursive fn make(depth: i64) -> Tree& {
    if depth == 0 { return scratch.push(Tree.Leaf); }
    let l: Tree& = make(depth - 1);
    let r: Tree& = make(depth - 1);
    return scratch.push(Tree.Node { left: l, right: r });
}

recursive fn check(t: Long&) -> i64 {
    match t {
        Node n => 1 + check(n.left) + check(n.right),
        _ => 1,
    }
}

recursive fn check(t: Tree&) -> i64 {
    match t {
        Node n => 1 + check(n.left) + check(n.right),
        _ => 1,
    }
}

fn tree_check(depth: i64) -> i64 {
    scratch = [];
    return check(make(depth));
}

fn main() {
    let a = args();
    var n = 10;
    if a.len > 1 { let v, ok = parse_int(a[1]); if ok { n = v; } }
    let max_depth = max(6, n);
    let stretch = max_depth + 1;
    print("stretch ", stretch, " ", tree_check(stretch));
    let long_lived: Long& = make_long(max_depth);
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
