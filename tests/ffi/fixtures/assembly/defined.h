/* A header defining a function, variables and a constructor with
   external linkage, which `file.c`, assembled apart, includes and so
   defines and runs too: each is defined, and the constructor run, once.
   `defined_base` is named by an `__asm__` label, which the glue's copy is
   matched by. */
#define TEXT(x) #x
#define SPELLED(x) TEXT(x)
#define SYMBOL(name) SPELLED(__USER_LABEL_PREFIX__) #name

long long defined_runs = 0;
long long defined_base __asm__(SYMBOL(defined_base_label)) = 1;
__attribute__((constructor)) static void defined_start(void) { defined_runs++; }
long long defined_twice(long long x) { return 2 * x + defined_runs + defined_base; }
