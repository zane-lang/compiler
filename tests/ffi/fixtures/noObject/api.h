#include <zane_ffi.h>

typedef struct conn_t conn_t;

conn_t *conn_none(void);
void conn_free(conn_t *conn);
