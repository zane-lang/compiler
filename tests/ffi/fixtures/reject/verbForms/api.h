#include <stdint.h>
typedef struct o_t o_t;
void o_free(o_t *o);
int64_t taken(const o_t *o);
o_t *referenced(void);
int64_t failing(int64_t n);
o_t *bad_abort(void);
