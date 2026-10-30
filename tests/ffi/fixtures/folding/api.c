#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "api.h"

int64_t fold_checksum(zane_bytes text) {
	uint64_t h = 1469598103934665603u;
	for (size_t i = 0; i < text.size; i++) h = (h ^ text.data[i]) * 1099511628211u;
	return (int64_t)(h >> 1);
}

struct buffer_t {
	int64_t count;
	int64_t room;
	int64_t *xs;
};

buffer_t *buffer_new(int64_t first) {
	buffer_t *b = malloc(sizeof *b);
	b->count = 1;
	b->room = 2;
	b->xs = malloc(2 * sizeof *b->xs);
	b->xs[0] = first;
	return b;
}

void buffer_push(buffer_t *b, int64_t x) {
	if (b->count == b->room) {
		b->room *= 2;
		b->xs = realloc(b->xs, (size_t)b->room * sizeof *b->xs);
	}
	b->xs[b->count++] = x;
}

int64_t buffer_sum(const buffer_t *b) {
	int64_t s = 0;
	for (int64_t i = 0; i < b->count; i++) s += b->xs[i];
	return s;
}

void buffer_free(buffer_t *b) {
	free(b->xs);
	free(b);
}

void buffer_set(buffer_t *into, buffer_t *from) {
	free(into->xs);
	*into = *from;
	free(from);
}

ticker_t zane_ticker;

int64_t ticker_next(ticker_t *ticker) { return ++ticker->ticks; }

double fold_sine(double x) { return sin(x); }

int64_t fold_sorted(bool (*before)(int64_t, int64_t), zane_span xs) {
	const int64_t *in = xs.data;
	int64_t *ys = malloc(xs.count * sizeof *ys);
	for (size_t i = 0; i < xs.count; i++) {
		size_t j = i;
		for (; j > 0 && before(in[i], ys[j - 1]); j--) ys[j] = ys[j - 1];
		ys[j] = in[i];
	}
	int64_t digits = 0;
	for (size_t i = 0; i < xs.count; i++) digits = digits * 10 + ys[i];
	free(ys);
	return digits;
}

zane_bytes fold_shout(zane_bytes text) {
	static uint8_t out[64];
	size_t n = text.size < sizeof out ? text.size : sizeof out;
	for (size_t i = 0; i < n; i++) out[i] = text.data[i] >= 'a' && text.data[i] <= 'z' ? text.data[i] - 32 : text.data[i];
	return (zane_bytes){ out, n };
}
