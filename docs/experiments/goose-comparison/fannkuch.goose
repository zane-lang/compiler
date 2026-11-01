// The Benchmarks Game's fannkuch-redux: every permutation of N items, each
// flipped by reversing its first k + 1 items while the first item k is not 0.
// N is the program's first argument.

import std;
import os;

fn main() {
    let a = args();
    var n = 7;
    if a.len > 1 { let v, ok = parse_int(a[1]); if ok { n = v; } }
    var perm1: i64[32] = [0; 32];
    var perm: i64[32] = [0; 32];
    var count: i64[32] = [0; 32];
    for i in n { perm1[i] = i; }
    var checksum = 0;
    var max_flips = 0;
    var r = n;
    var sign = 1;
    loop {
        while r != 1 { count[r - 1] = r; r--; }
        for i in n { perm[i] = perm1[i]; }
        var flips = 0;
        var k = perm[0];
        while k != 0 {
            var i = 0;
            var j = k;
            while i < j {
                let t = perm[i];
                perm[i] = perm[j];
                perm[j] = t;
                i++;
                j--;
            }
            flips++;
            k = perm[0];
        }
        if max_flips < flips { max_flips = flips; }
        checksum += sign * flips;
        sign = -sign;
        loop {
            if r == n {
                print(checksum, " ", max_flips);
                return;
            }
            let first = perm1[0];
            for i in r { perm1[i] = perm1[i + 1]; }
            perm1[r] = first;
            count[r] -= 1;
            if count[r] > 0 { break; }
            r++;
        }
    }
}
