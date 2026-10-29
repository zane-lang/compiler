#include "plain.h"

int plus(int a, int b) { return a + b; }
long long widen(long long x) { return x * 1000000000LL; }

extern long long primed_runs;
__attribute__((constructor)) static void prime_run(void) { primed_runs++; }
