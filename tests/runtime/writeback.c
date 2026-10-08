/* A write-back's stores, as a reader that loads a naturally aligned word in
   one access sees them (runtime/snapshot.c): never torn, wherever the
   subject and the spawned call's copy sit. Each check prints `yes` when it
   holds and `no` when it does not. */

#include "zane_internal.h"

#include <pthread.h>

static void check(int ok) { puts(ok ? "yes" : "no"); }

/* The subject is 16 bytes at an address aligned to 4 and not 8, so its
   words are a 4-byte one, an 8-byte one and a 4-byte one. */
static char *subject;
static int stop, torn, seen;

/* Every word must hold all of one pattern: no bits or every bit set. */
static void *reader(void *unused) {
	(void)unused;
	while (!__atomic_load_n(&stop, __ATOMIC_ACQUIRE)) {
		uint32_t first = __atomic_load_n((uint32_t *)subject, __ATOMIC_RELAXED);
		uint64_t middle = __atomic_load_n((uint64_t *)(subject + 4), __ATOMIC_RELAXED);
		uint32_t last = __atomic_load_n((uint32_t *)(subject + 12), __ATOMIC_RELAXED);
		torn |= (first != 0 && first != UINT32_MAX) || (middle != 0 && middle != UINT64_MAX) ||
		        (last != 0 && last != UINT32_MAX);
		__atomic_fetch_add(&seen, 1, __ATOMIC_RELAXED);
	}
	return NULL;
}

void zane_main(void) {
	int64_t scope = zane_scope_enter();
	char *slot = zane_slot(scope, 32, 8, NULL);
	subject = slot + 4;
	memset(subject, 0, 16);
	/* The copies sit one byte past an aligned address, as no word of the
	   subject does. */
	char copies[2][24];
	memset(copies[0], 0, sizeof copies[0]);
	memset(copies[1], 0xff, sizeof copies[1]);

	pthread_t thread;
	if (pthread_create(&thread, NULL, reader, NULL) != 0) zane_broken("no thread for the reader");
	while (!__atomic_load_n(&seen, __ATOMIC_RELAXED)) sched_yield();
	for (int i = 0; i < 400000; i++) zane_writeback(subject, copies[i % 2] + 1, 16, NULL);
	__atomic_store_n(&stop, 1, __ATOMIC_RELEASE);
	pthread_join(thread, NULL);
	check(!torn);

	/* A subject of any size and alignment ends up holding the copy. */
	int all = 1;
	for (int offset = 0; offset < 8; offset++)
		for (int size = 1; size <= 19; size++) {
			char source[24];
			for (int i = 0; i < 24; i++) source[i] = (char)(offset * 31 + size * 7 + i);
			memset(slot, 0, 32);
			zane_writeback(slot + offset, source + (size % 3), size, NULL);
			all &= memcmp(slot + offset, source + (size % 3), (size_t)size) == 0;
		}
	check(all);
	zane_scope_drain(scope);
}
