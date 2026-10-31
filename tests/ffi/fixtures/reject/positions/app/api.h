#include <stdint.h>
#include "../io/io.h"
typedef struct data_t data_t;
void data_free(data_t *d);
int64_t capability_param(const io_t *c);
int64_t data_writable(data_t *d);
int64_t data_const(const data_t *d);
int64_t data_param_writable(data_t *d);
const data_t *data_const_result(void);
io_t *capability_result(void);
