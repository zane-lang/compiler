#include <stdint.h>

/* A private function whose address an external function of the header
   lets out, which a `static inline` function compares with its own. */
static int64_t token(void) { return 1; }
int64_t (*token_at(void))(void) { return token; }
static inline int64_t token_same(void) { return token_at() == token; }
