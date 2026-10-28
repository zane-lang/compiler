#include "lib.h"
struct io_t { int unused; };
struct other_t { int unused; };
io_t io_global;
_Thread_local io_t io_thread;
other_t io_other;
