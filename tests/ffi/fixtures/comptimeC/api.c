#include "api.h"

int64_t marked_checksum(zane_bytes text) {
	uint64_t h = 1469598103934665603u;
	for (size_t i = 0; i < text.size; i++) h = (h ^ text.data[i]) * 1099511628211u;
	return (int64_t)(h >> 1);
}

counter_t zane_counter = { 7 };

int64_t counter_read(const counter_t *counter) { return counter->count; }

void counter_bump(counter_t *counter) { counter->count++; }
