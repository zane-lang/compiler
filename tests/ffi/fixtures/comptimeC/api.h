#include <stdint.h>
#include <zane_ffi.h>

/* FNV-1a over a string's bytes. */
int64_t marked_checksum(zane_bytes text);

/* A number C keeps outside the program, reached through a capability. */
typedef struct counter_t { int64_t count; } counter_t;
extern counter_t zane_counter;
int64_t counter_read(const counter_t *counter);
void counter_bump(counter_t *counter);
