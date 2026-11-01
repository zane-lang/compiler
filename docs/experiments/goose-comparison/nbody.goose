// The Benchmarks Game's n-body: the Sun and the four gas giants, advanced
// N steps of 0.01 days. It prints the system's energy before and after, in
// billionths, truncated. N is the program's first argument.

import std;
import os;
import math;

let SOLAR_MASS = 4.0 * PI * PI;
let YEAR = 365.24;

struct Body { x: f64, y: f64, z: f64, vx: f64, vy: f64, vz: f64, mass: f64 }

fn solar_system() -> Body[5] {
    [
        Body { 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, SOLAR_MASS },
        Body { 4.84143144246472090, -1.16032004402742839, -0.103622044471123109,
               0.00166007664274403694 * YEAR, 0.00769901118419740425 * YEAR, -0.0000690460016972063023 * YEAR,
               0.000954791938424326609 * SOLAR_MASS },
        Body { 8.34336671824457987, 4.12479856412430479, -0.403523417114321381,
               -0.00276742510726862411 * YEAR, 0.00499852801234917238 * YEAR, 0.0000230417297573763929 * YEAR,
               0.000285885980666130812 * SOLAR_MASS },
        Body { 12.8943695621391310, -15.1111514016986312, -0.223307578892655734,
               0.00296460137564761618 * YEAR, 0.00237847173959480950 * YEAR, -0.0000296589568540237556 * YEAR,
               0.0000436624404335156298 * SOLAR_MASS },
        Body { 15.3796971148509165, -25.9193146099879641, 0.179258772950371181,
               0.00268067772490389322 * YEAR, 0.00162824170038242295 * YEAR, -0.0000951592254519715870 * YEAR,
               0.0000515138902046611451 * SOLAR_MASS },
    ]
}

fn offset_momentum(b: Body[5]&) {
    var px = 0.0;
    var py = 0.0;
    var pz = 0.0;
    for q in b {
        px = px + q.vx * q.mass;
        py = py + q.vy * q.mass;
        pz = pz + q.vz * q.mass;
    }
    b[0].vx = -px / SOLAR_MASS;
    b[0].vy = -py / SOLAR_MASS;
    b[0].vz = -pz / SOLAR_MASS;
}

fn advance(b: Body[5]&, dt: f64) {
    for i in 5 {
        for j in i + 1..5 {
            let dx = b[i].x - b[j].x;
            let dy = b[i].y - b[j].y;
            let dz = b[i].z - b[j].z;
            let d2 = dx * dx + dy * dy + dz * dz;
            let mag = dt / (d2 * sqrt(d2));
            b[i].vx = b[i].vx - dx * b[j].mass * mag;
            b[i].vy = b[i].vy - dy * b[j].mass * mag;
            b[i].vz = b[i].vz - dz * b[j].mass * mag;
            b[j].vx = b[j].vx + dx * b[i].mass * mag;
            b[j].vy = b[j].vy + dy * b[i].mass * mag;
            b[j].vz = b[j].vz + dz * b[i].mass * mag;
        }
    }
    for &q in b {
        q.x = q.x + dt * q.vx;
        q.y = q.y + dt * q.vy;
        q.z = q.z + dt * q.vz;
    }
}

fn energy(b: Body[5]&) -> f64 {
    var e = 0.0;
    for i in 5 {
        e = e + 0.5 * b[i].mass * (b[i].vx * b[i].vx + b[i].vy * b[i].vy + b[i].vz * b[i].vz);
        for j in i + 1..5 {
            let dx = b[i].x - b[j].x;
            let dy = b[i].y - b[j].y;
            let dz = b[i].z - b[j].z;
            e = e - b[i].mass * b[j].mass / sqrt(dx * dx + dy * dy + dz * dz);
        }
    }
    return e;
}

fn main() {
    let a = args();
    var n = 1000;
    if a.len > 1 { let v, ok = parse_int(a[1]); if ok { n = v; } }
    var bodies = solar_system();
    offset_momentum(bodies);
    let before = energy(bodies);
    for step in n { advance(bodies, 0.01); }
    let after = energy(bodies);
    print(n, " ", (before * 1e9) as i64, " ", (after * 1e9) as i64);
}
