#include "api.h"

#include <stdlib.h>

struct obj_t { int64_t value; };
struct log_t { int64_t freed; };
log_t zane_log;

obj_t *obj_new(int64_t value) {
    obj_t *o = malloc(sizeof *o);
    o->value = value;
    return o;
}

void obj_free(obj_t *o) {
    zane_log.freed += o->value;
    free(o);
}

int64_t obj_value(const obj_t *o) { return o->value; }

int64_t each_word(int64_t (*f)(zane_bytes word), zane_bytes text) {
    int64_t total = 0;
    size_t start = 0;
    for (size_t i = 0; i <= text.size; i++) {
        if (i == text.size || text.data[i] == ' ') {
            total += f((zane_bytes){ text.data + start, i - start });
            start = i + 1;
        }
    }
    return total;
}

int64_t with_list(int64_t (*f)(zane_span xs)) {
    int64_t xs[4] = { 1, 2, 3, 4 };
    return f((zane_span){ xs, 4 });
}

int64_t with_array(int64_t (*f)(const int64_t *xs)) {
    int64_t xs[3] = { 5, 6, 7 };
    return f(xs);
}

int64_t with_object(int64_t (*f)(const obj_t *o), const obj_t *o) { return f(o); }

void log_give(log_t *log, void (*f)(obj_t *o), int64_t value) {
    (void)log;
    f(obj_new(value));
}

int64_t log_freed(const log_t *log) { return log->freed; }
