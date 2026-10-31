#include "lib.h"

static int64_t counter;

lib_state_t lib_state;

int64_t next(lib_state_t *state) { state->calls++; return ++counter; }

static const int64_t token = 5;
const int64_t *token_seen;

void token_record(lib_state_t *state) { state->calls++; token_seen = &token; }

int64_t token_same(const lib_state_t *state) { (void)state; return token_seen == &token; }

int64_t starts;

__attribute__((constructor)) void start(void) { starts++; }

int64_t started(void) { return starts; }
