// The Benchmarks Game's spectral-norm: the largest singular value of an
// infinite matrix, by 10 rounds of the power method on its N by N corner.
// It prints the value in billionths, truncated. N is the program's first
// argument.

import std;
import os;
import math;

fn entry(i: i64, j: i64) -> f64 {
    1.0 / (((i + j) * (i + j + 1) / 2 + i + 1) as f64)
}

fn times(v: f64[:], out: f64[:]) {
    for i in out.len {
        var sum = 0.0;
        for j in v.len { sum = sum + entry(i, j) * v[j]; }
        out[i] = sum;
    }
}

fn times_transposed(v: f64[:], out: f64[:]) {
    for i in out.len {
        var sum = 0.0;
        for j in v.len { sum = sum + entry(j, i) * v[j]; }
        out[i] = sum;
    }
}

fn times_both(v: f64[:], out: f64[:], tmp: f64[:]) {
    times(v, tmp);
    times_transposed(tmp, out);
}

fn main() {
    let a = args();
    var n = 100;
    if a.len > 1 { let v, ok = parse_int(a[1]); if ok { n = v; } }
    var u: f64[>..] = [];
    var v: f64[>..] = [];
    var tmp: f64[>..] = [];
    u.resize(n, 1.0);
    v.resize(n, 0.0);
    tmp.resize(n, 0.0);
    for round in 10 {
        times_both(u, v, tmp);
        times_both(v, u, tmp);
    }
    var vbv = 0.0;
    var vv = 0.0;
    for k in n {
        vbv = vbv + u[k] * v[k];
        vv = vv + v[k] * v[k];
    }
    print(n, " ", (sqrt(vbv / vv) * 1e9) as i64);
}
