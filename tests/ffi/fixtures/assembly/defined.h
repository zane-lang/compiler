/* A header defining a function, a variable and a constructor with
   external linkage, which `file.c`, assembled apart, includes and so
   defines and runs too: each is defined, and the constructor run, once. */
long long defined_runs = 0;
__attribute__((constructor)) static void defined_start(void) { defined_runs++; }
long long defined_twice(long long x) { return 2 * x + defined_runs; }
