#include "inner.h"
typedef union { int a; float b; } u_t;
typedef struct a_t a_t;
void a_release(const a_t *a);
int a_close(a_t *a);
float a_measure(a_t *a);
void a_free(a_t *a);
void a_swap(a_t *dst);
int inner_size(const inner_t *inner);
extern inner_t inner_global;
int missing_size(const int *missing);
extern int missing_global;
