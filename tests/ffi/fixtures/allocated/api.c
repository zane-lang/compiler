#include "api.h"

struct texts_t { const uint8_t *given; };
texts_t zane_texts;

static uint8_t upper(uint8_t c) { return c >= 'a' && c <= 'z' ? (uint8_t)(c - 32) : c; }

zane_bytes texts_upper(texts_t *t, zane_bytes s) {
    uint8_t *out = zane_bytes_alloc(s.size);
    for (size_t i = 0; i < s.size; i++) out[i] = upper(s.data[i]);
    t->given = out;
    return (zane_bytes){ out, s.size };
}

zane_bytes texts_prefix(texts_t *t, zane_bytes s, int64_t n) {
    uint8_t *out = zane_bytes_alloc(s.size);
    for (size_t i = 0; i < s.size; i++) out[i] = s.data[i];
    t->given = out;
    return (zane_bytes){ out, (size_t)n };
}

zane_bytes texts_fixed(texts_t *t) {
    static const uint8_t fixed[] = "fixed";
    t->given = 0;
    return (zane_bytes){ fixed, 5 };
}

zane_bytes texts_empty(texts_t *t) {
    t->given = zane_bytes_alloc(0);
    return (zane_bytes){ t->given, 0 };
}

int64_t texts_kept(texts_t *t, zane_bytes s) { return s.size > 0 && s.data == t->given; }

zane_bytes texts_pure(zane_bytes s) {
    uint8_t *out = zane_bytes_alloc(s.size + 1);
    for (size_t i = 0; i < s.size; i++) out[i] = upper(s.data[i]);
    out[s.size] = '!';
    return (zane_bytes){ out, s.size + 1 };
}
