#include <zane_ffi.h>

typedef struct obj_t obj_t;
typedef struct cap_t cap_t;

void obj_free(obj_t *o);
obj_t *obj_new(void);
int64_t named(int64_t (*f)(const char *name));
int64_t wrong_object(int64_t (*f)(const cap_t *o));
int64_t with_cap(int64_t (*f)(const cap_t *c));
int64_t with_view(int64_t (*f)(zane_bytes s));
