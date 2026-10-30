#include "lib.h"

static int64_t counter;

int64_t next(void) { return ++counter; }

static const int64_t token = 5;
const int64_t *token_seen;

void token_record(void) { token_seen = &token; }

int64_t token_same(void) { return token_seen == &token; }

int64_t starts;

__attribute__((constructor)) void start(void) { starts++; }

int64_t started(void) { return starts; }
