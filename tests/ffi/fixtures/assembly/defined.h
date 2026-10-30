/* A header defining a function, variables and constructors, one local and
   one with external linkage, which `file.c`, assembled apart, includes
   and so defines and runs too: each is defined, and each constructor run,
   once.
   `defined_base` is named by an `__asm__` label, which the glue's copy is
   matched by. */
#define TEXT(x) #x
#define SPELLED(x) TEXT(x)
#define SYMBOL(name) SPELLED(__USER_LABEL_PREFIX__) #name

long long defined_runs = 0;
long long defined_base __asm__(SYMBOL(defined_base_label)) = 1;
__attribute__((constructor)) static void defined_start(void) { defined_runs++; }
/* Read through `volatile`, so no optimizer runs the constructor as it
   compiles it. */
volatile long long defined_step = 10;
__attribute__((constructor)) void defined_external_start(void) { defined_runs += defined_step; }
long long defined_twice(long long x) { return 2 * x + defined_runs + defined_base; }
