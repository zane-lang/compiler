#include <zane_ffi.h>

typedef struct obj_t obj_t;

int64_t with_null(int64_t (*f)(const obj_t *o));
void obj_free(obj_t *o);
