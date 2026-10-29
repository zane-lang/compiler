// The Mandelbrot set on an N by N grid: how many points stay bounded for 50
// iterations. N is the program's first argument.

import std;
import os;

fn bounded(cr: f64, ci: f64) -> bool {
    var zr = 0.0;
    var zi = 0.0;
    for i in 50 {
        let tr = zr * zr - zi * zi + cr;
        zi = 2.0 * zr * zi + ci;
        zr = tr;
        if 4.0 < zr * zr + zi * zi { return false; }
    }
    return true;
}

fn main() {
    let a = args();
    var n = 200;
    if a.len > 1 { let v, ok = parse_int(a[1]); if ok { n = v; } }
    let size = n as f64;
    var inside = 0;
    for y in n {
        for x in n {
            if bounded(2.0 * (x as f64) / size - 1.5, 2.0 * (y as f64) / size - 1.0) { inside++; }
        }
    }
    print(n, " ", inside);
}
