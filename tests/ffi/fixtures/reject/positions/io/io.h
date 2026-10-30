#ifndef IO_H
#define IO_H
#include <stdint.h>
typedef struct io_t io_t;
typedef struct port_t port_t;
port_t *port_open(const io_t *io);
int64_t port_subject(const port_t *p);
int64_t port_param(const port_t *p);
port_t *mixed_from_io(io_t *io);
port_t *mixed_plain(void);
void port_close(port_t *p);
#endif
