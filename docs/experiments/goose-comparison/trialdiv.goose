// The primes up to N, counted by trial division against a table of small
// primes built with a sieve. N is the program's first argument.

import std;
import os;

let TABLE_BOUND = 4000;

fn primes_below(table: i64[>..]&, bound: i64) {
    var composite: bool[TABLE_BOUND] = [false; TABLE_BOUND];
    for p in 2..bound {
        if composite[p] { continue; }
        table.push(p);
        var m = p * p;
        while m < bound { composite[m] = true; m += p; }
    }
}

fn is_prime(table: i64[:], k: i64) -> bool {
    for p in table {
        if k < p * p { return true; }
        if k % p == 0 { return false; }
    }
    return true;
}

fn main() {
    let a = args();
    var n = 100000;
    if a.len > 1 { let v, ok = parse_int(a[1]); if ok { n = v; } }
    var table: i64[>..] = [];
    primes_below(table, TABLE_BOUND);
    var count = 0;
    for k in 2..n + 1 {
        if is_prime(table, k) { count++; }
    }
    print(n, " ", count);
}
