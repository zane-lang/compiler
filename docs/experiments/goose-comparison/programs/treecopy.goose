// A perfect binary tree N levels deep, copied whole 20 times; each copy is
// checked and dropped. N is the program's first argument. Each tree is one
// pool of nodes linked by self-relative references, local to the scope that
// owns it; a copy is built node by node into a fresh pool.

import std;
import os;

struct Node { left: Node&<u32>?, right: Node&<u32>?, value: i64 }

recursive fn make(pool: Node[>..]&, depth: i64, value: i64) -> Node& {
    if depth == 0 { return pool.push(Node { value: value, .. }); }
    let l: Node& = make(pool, depth - 1, 2 * value);
    let r: Node& = make(pool, depth - 1, 2 * value + 1);
    return pool.push(Node { left: l, right: r, value: value });
}

recursive fn copy_tree(pool: Node[>..]&, n: Node&) -> Node& {
    let l = n.left;
    guard l else { return pool.push(Node { value: n.value, .. }); }
    let r = n.right;
    guard r else { return pool.push(Node { value: n.value, .. }); }
    let cl: Node& = copy_tree(pool, l);
    let cr: Node& = copy_tree(pool, r);
    return pool.push(Node { left: cl, right: cr, value: n.value });
}

recursive fn sum(n: Node&) -> i64 {
    let l = n.left;
    guard l else { return n.value; }
    let r = n.right;
    guard r else { return n.value; }
    return n.value + sum(l) + sum(r);
}

fn main() {
    let a = args();
    var depth = 12;
    if a.len > 1 { let v, ok = parse_int(a[1]); if ok { depth = v; } }
    var original: Node[>..] = [];
    let root: Node& = make(original, depth, 1);
    var total = 0;
    for round in 20 {
        var pool: Node[>..] = [];
        total += sum(copy_tree(pool, root));
    }
    print(depth, " ", total, " ", sum(root));
}
