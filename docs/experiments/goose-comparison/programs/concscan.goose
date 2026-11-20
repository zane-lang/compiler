// N entities held inline in one array, split into four shards, each shard
// summed on its own thread, 100 times over. N is the program's first
// argument. Goose threads share no memory, so each worker is handed its
// shard as a copy, and sends its sum back through a queue.

import std;
import os;

struct Entity { id: i64, x: f64, y: f64, hp: i64 }
struct Shard { slot: i64, entities: Entity[] }
struct Sum { slot: i64, sum: i64 }

thread_fn shard_sum(shard: Shard) {
    var sum = 0;
    for e in shard.entities { sum += e.hp; }
    qput(Sum { slot: shard.slot, sum: sum });
}

fn main() {
    let a = args();
    var n = 100000;
    if a.len > 1 { let v, ok = parse_int(a[1]); if ok { n = v; } }
    var entities: Entity[>..] = [];
    for i in 1..n + 1 {
        entities.push(Entity { i, 1.1 * (i as f64), 2.2 * (i as f64), i % 100 + 1 });
    }
    var total = 0;
    for pass in 100 {
        var ids: i64[4] = [0; 4];
        for s in 4 {
            ids[s] = thread_spawn(shard_sum, Shard { slot: s, entities: entities[n * s / 4..n * (s + 1) / 4] });
        }
        for s in 4 { total += qget<Sum>().sum; }
        for id in ids { thread_wait(id); }
    }
    print(n, " ", total);
}
