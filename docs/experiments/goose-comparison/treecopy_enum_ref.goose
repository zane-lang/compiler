// treecopy with the tree as a fixed-mode enum linked by plain 8-byte
// references: the same pools and rounds as treecopy.goose, a leaf a variant
// of its own instead of a node with null links.

import std;
import os;

enum Tree {
    Leaf { value: i64 },
    Node { left: Tree&, right: Tree&, value: i64 },
}

recursive fn make(pool: Tree[>..]&, depth: i64, value: i64) -> Tree& {
    if depth == 0 { return pool.push(Tree.Leaf { value: value }); }
    let l: Tree& = make(pool, depth - 1, 2 * value);
    let r: Tree& = make(pool, depth - 1, 2 * value + 1);
    return pool.push(Tree.Node { left: l, right: r, value: value });
}

recursive fn copy_tree(pool: Tree[>..]&, t: Tree&) -> Tree& {
    match t {
        Leaf l => pool.push(Tree.Leaf { value: l.value }),
        Node n => {
            let cl: Tree& = copy_tree(pool, n.left);
            let cr: Tree& = copy_tree(pool, n.right);
            pool.push(Tree.Node { left: cl, right: cr, value: n.value })
        },
    }
}

recursive fn sum(t: Tree&) -> i64 {
    match t {
        Leaf l => l.value,
        Node n => n.value + sum(n.left) + sum(n.right),
    }
}

fn main() {
    let a = args();
    var depth = 12;
    if a.len > 1 { let v, ok = parse_int(a[1]); if ok { depth = v; } }
    var original: Tree[>..] = [];
    let root: Tree& = make(original, depth, 1);
    var total = 0;
    for round in 20 {
        var pool: Tree[>..] = [];
        total += sum(copy_tree(pool, root));
    }
    print(depth, " ", total, " ", sum(root));
}
