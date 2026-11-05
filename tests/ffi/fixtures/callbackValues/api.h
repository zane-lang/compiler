#include <zane_ffi.h>

typedef struct obj_t obj_t;
typedef struct log_t log_t;

extern log_t zane_log;

obj_t *obj_new(int64_t value);
void obj_free(obj_t *o);
int64_t obj_value(const obj_t *o);

int64_t each_word(int64_t (*f)(zane_bytes word), zane_bytes text);
int64_t with_list(int64_t (*f)(zane_span xs));
int64_t with_array(int64_t (*f)(const int64_t *xs));
int64_t with_object(int64_t (*f)(const obj_t *o), const obj_t *o);
void log_give(log_t *log, void (*f)(obj_t *o), int64_t value);
int64_t log_freed(const log_t *log);
int64_t with_scratch(int64_t (*f)(zane_bytes text));
int64_t scribble(void);
