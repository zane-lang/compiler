// The primes below a fixed bound, found with a sieve, counted and summed.

let BOUND = 20000;

fn main() {
    var composite: bool[BOUND] = [false; BOUND];
    var count = 0;
    var sum = 0;
    for p in 2..BOUND {
        if composite[p] { continue; }
        count++;
        sum += p;
        var m = p * p;
        while m < BOUND { composite[m] = true; m += p; }
    }
    print(count, " ", sum);
}
