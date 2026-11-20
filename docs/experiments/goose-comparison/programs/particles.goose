// A particle system over F frames: each frame spawns a burst of 60
// particles with 10 to 30 frames to live, then moves the living and
// expires the rest. Order does not matter, so an expired particle's slot
// takes the last one. F is the program's first argument. Particles come
// from a reusable pool; the list holds 4-byte links into it.

import std;
import os;

struct Particle { x: f64, y: f64, vx: f64, vy: f64, ttl: i64, color: i64 }

reusable var pool: Particle[>..] = [];
var state = 42;

fn below(bound: i64) -> i64 {
    state = (state * 1103515245 + 12345) & 2147483647;
    return state % bound;
}

fn main() {
    let a = args();
    var frames = 500;
    if a.len > 1 { let v, ok = parse_int(a[1]); if ok { frames = v; } }
    var particles: (Particle&<u32 in pool>)[>..<] = [];
    var total = 0;
    for frame in frames {
        for s in 60 {
            let x = below(800) as f64;
            let y = below(600) as f64;
            let vx = (below(11) - 5) as f64;
            let vy = (below(11) - 5) as f64;
            let ttl = 10 + below(21);
            let color = below(8);
            particles.push(pool.alloc_ref(Particle { x, y, vx, vy, ttl, color }));
        }
        var sum = 0.0;
        var k = 0;
        for u in particles.len {
            let p .= particles[k];
            p.ttl = p.ttl - 1;
            if p.ttl < 1 {
                let slot = pool.index_of(p);
                particles.swap_remove(k);
                pool.free(slot);
            } else {
                p.x = p.x + p.vx;
                p.y = p.y + p.vy;
                sum = sum + p.x;
                k++;
            }
        }
        total += sum as i64;
    }
    print(frames, " ", particles.len, " ", total);
}
