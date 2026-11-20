// treecopy with the tree as a fixed-mode enum linked by 4-byte pool-relative
// references. A pool-relative link names a global pool in its type, so the
// original and the copies are two enums over two global pools, and each
// round's copy is dropped by emptying its pool.

import std;
import os;

var originals: Tree[>..] = [];
var copies: Copy[>..] = [];

enum Tree {
    Leaf { value: i64 },
    Node { left: Tree&<u32 in originals>, right: Tree&<u32 in originals>, value: i64 },
}

enum Copy {
    Leaf { value: i64 },
    Node { left: Copy&<u32 in copies>, right: Copy&<u32 in copies>, value: i64 },
}

recursive fn make(depth: i64, value: i64) -> Tree& {
    if depth == 0 { return originals.push(Tree.Leaf { value: value }); }
    let l: Tree& = make(depth - 1, 2 * value);
    let r: Tree& = make(depth - 1, 2 * value + 1);
    return originals.push(Tree.Node { left: l, right: r, value: value });
}

recursive fn copy_tree(t: Tree&) -> Copy& {
    match t {
        Leaf l => copies.push(Copy.Leaf { value: l.value }),
        Node n => {
            let cl: Copy& = copy_tree(n.left);
            let cr: Copy& = copy_tree(n.right);
            copies.push(Copy.Node { left: cl, right: cr, value: n.value })
        },
    }
}

recursive fn sum(t: Tree&) -> i64 {
    match t {
        Leaf l => l.value,
        Node n => n.value + sum(n.left) + sum(n.right),
    }
}

recursive fn sum(t: Copy&) -> i64 {
    match t {
        Leaf l => l.value,
        Node n => n.value + sum(n.left) + sum(n.right),
    }
}

fn main() {
    let a = args();
    var depth = 12;
    if a.len > 1 { let v, ok = parse_int(a[1]); if ok { depth = v; } }
    let root: Tree& = make(depth, 1);
    var total = 0;
    for round in 20 {
        copies = [];
        total += sum(copy_tree(root));
    }
    print(depth, " ", total, " ", sum(root));
}
