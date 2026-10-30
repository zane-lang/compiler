#include "inner.h"
typedef union { int a; float b; } u_t;
typedef struct a_t a_t;
void a_release(const a_t *a);
int a_close(a_t *a);
void a_free(a_t *a);
void a_swap(a_t *dst);
