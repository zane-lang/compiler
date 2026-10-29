// A game loop over F frames: each frame spawns 30 entities, kills the 20
// oldest, and updates the rest, removing those whose hit points run out.
// The list keeps the entities in the order they spawned. F is the
// program's first argument. Entities come from a reusable pool; the list
// holds 4-byte links into it.

import std;
import os;

struct Entity { id: i64, x: f64, y: f64, hp: i64 }

reusable var pool: Entity[>..] = [];
var state = 42;

fn below(bound: i64) -> i64 {
    state = (state * 1103515245 + 12345) & 2147483647;
    return state % bound;
}

fn main() {
    let a = args();
    var frames = 500;
    if a.len > 1 { let v, ok = parse_int(a[1]); if ok { frames = v; } }
    var entities: (Entity&<u32 in pool>)[>..<] = [];
    var total = 0;
    for frame in frames {
        for s in 30 {
            let x = below(1000) as f64;
            let y = below(1000) as f64;
            let id = below(100);
            let hp = 50 + below(50);
            entities.push(pool.alloc_ref(Entity { id, x, y, hp }));
        }
        let kills = min(entities.len, 20);
        for d in kills {
            let slot = pool.index_of(entities[0]);
            entities.remove_at(0);
            pool.free(slot);
        }
        var k = 0;
        for u in entities.len {
            let e .= entities[k];
            e.x = e.x + (e.id as f64) * 0.1;
            e.y = e.y + (e.hp as f64) * 0.05;
            e.hp = e.hp - 1;
            if e.hp < 1 {
                let slot = pool.index_of(e);
                entities.remove_at(k);
                pool.free(slot);
            } else {
                total += e.hp;
                k++;
            }
        }
    }
    print(frames, " ", entities.len, " ", total);
}
