#include <stdint.h>

int64_t add(int64_t a, int64_t b);
int64_t square(int64_t i);
/* The state the calls below keep, which the program reaches through a
   capability: C variables another call changes are outside state. */
typedef struct lib_state_t { int64_t calls; } lib_state_t;
extern lib_state_t lib_state;

int64_t next(lib_state_t *state);
void token_record(lib_state_t *state);
int64_t token_same(const lib_state_t *state);
int64_t started(void);
int64_t fenced(int64_t x);
