#include <stdint.h>

/* A private constant whose address an external function of the header
   lets out, which a `static inline` function compares with its own. */
static const int64_t token = 1;
const int64_t *token_at(void) { return &token; }
static inline int64_t token_same(void) { return token_at() == &token; }
