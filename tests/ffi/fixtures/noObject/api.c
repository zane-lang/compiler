#include <stddef.h>

#include "api.h"

conn_t *conn_none(void) { return NULL; }

void conn_free(conn_t *conn) { (void)conn; }
