#include <stddef.h>

#include "api.h"

int64_t with_null(int64_t (*f)(const obj_t *o)) { return f(NULL); }

void obj_free(obj_t *o) { (void)o; }
