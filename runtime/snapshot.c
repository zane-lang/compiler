#include "zane_internal.h"

/* ---------------------------------------------------------------------- */
/* Snapshots (concurrency.md §4.4, docs/design/lowering.md §9)                   */
/* ---------------------------------------------------------------------- */

/* A spawned `mut` call whose subject is reached through an owner works on a
   copy of its own, and writes it back when it returns. A write-back counts
   itself begun, replaces the bytes, and counts itself done. A value reached
   through an owner that is 8 bytes aligned to 8 is read in one access,
   which the write-back never tears. Any other is read here: its bytes are taken when every write-back begun is done, and
   kept when none began while they were read. */
static uint64_t zane_begun, zane_done;

/* A read of `size` bytes that tolerates a write-back mid-way: a word at a
   time where both ends allow it, as atomics, so the copy is torn only where
   the version check retries it. */
static void zane_racy_load(char *to, const char *from, int64_t size) {
	int64_t i = 0;
	if (((uintptr_t)to | (uintptr_t)from) % 8 == 0)
		for (; i + 8 <= size; i += 8)
			*(uint64_t *)(to + i) = __atomic_load_n((const uint64_t *)(from + i), __ATOMIC_RELAXED);
	for (; i < size; i++) to[i] = __atomic_load_n(from + i, __ATOMIC_RELAXED);
}

/* A write-back's bytes, each piece stored in one atomic access of the
   widest width, up to 8, that its address is aligned to and the rest of the
   value holds; the source is the spawned call's own copy, read plainly. Two
   aligned pieces of power-of-two widths either nest or do not meet, so every
   naturally aligned 1, 2, 4 or 8 bytes of the value is written by a single
   store, and a reader that loads it in one access is never torn. Emitted
   code reads an 8-byte value aligned to 8 that way, without the version
   check: it is exactly one piece, whatever value around it is written back. */
static void zane_racy_store(char *to, const char *from, int64_t size) {
	for (int64_t i = 0; i < size;) {
		uintptr_t at = (uintptr_t)(to + i);
		int64_t left = size - i;
		if (at % 8 == 0 && left >= 8) {
			uint64_t w;
			memcpy(&w, from + i, 8);
			__atomic_store_n((uint64_t *)(to + i), w, __ATOMIC_RELAXED);
			i += 8;
		} else if (at % 4 == 0 && left >= 4) {
			uint32_t w;
			memcpy(&w, from + i, 4);
			__atomic_store_n((uint32_t *)(to + i), w, __ATOMIC_RELAXED);
			i += 4;
		} else if (at % 2 == 0 && left >= 2) {
			uint16_t w;
			memcpy(&w, from + i, 2);
			__atomic_store_n((uint16_t *)(to + i), w, __ATOMIC_RELAXED);
			i += 2;
		} else {
			__atomic_store_n(to + i, from[i], __ATOMIC_RELAXED);
			i += 1;
		}
	}
}

/* A coherent copy of the `size` bytes at `from` into `out`. The blocks
   they name stay as they are while it is read: a write-back retires the
   ones it replaces rather than returning them. */
void zane_snapshot(char *out, const char *from, int64_t size) {
	for (;;) {
		uint64_t done = __atomic_load_n(&zane_done, __ATOMIC_ACQUIRE);
		uint64_t begun = __atomic_load_n(&zane_begun, __ATOMIC_ACQUIRE);
		if (begun != done) {
			sched_yield();
			continue;
		}
		zane_racy_load(out, from, size);
		__atomic_thread_fence(__ATOMIC_ACQUIRE);
		if (__atomic_load_n(&zane_begun, __ATOMIC_RELAXED) == begun) return;
	}
}

/* The copy a spawned call worked on replaces its subject at `at`. What the
   copy owns moves into the subject's region first. What the subject owned
   is never returned, since a reader may still be following it: it stays
   where it is until its region drains, and is retired there when drains
   are checked. */
void zane_writeback(char *at, char *copy, int64_t size, const zane_type *type) {
	if (type) {
		zane_mark *region = zane_region_at(at);
		zane_move(copy, type, region, 0);
		if (zane_checking) {
			zane_retired *r = (zane_retired *)zane_alloc(region, (int64_t)sizeof *r + size, 8);
			memcpy(r + 1, at, (size_t)size);
			r->type = type;
			r->size = size;
			zane_lock(region->context);
			r->next = region->retired;
			region->retired = r;
			zane_unlock(region->context);
		}
	}
	__atomic_fetch_add(&zane_begun, 1, __ATOMIC_RELAXED);
	__atomic_thread_fence(__ATOMIC_RELEASE);
	zane_racy_store(at, copy, size);
	__atomic_fetch_add(&zane_done, 1, __ATOMIC_RELEASE);
}

/* A checked drain: what the region's values and retired values own is
   returned, block by block, and by then no block is out in the region,
   since every one has an owner in the scope or has moved out with it. */
static void zane_check(zane_mark *m) {
	for (zane_held *h = m->held; h; h = h->next) zane_end(h->slot, h->type);
	while (m->retired) {
		zane_retired *r = m->retired;
		m->retired = r->next;
		zane_end((char *)(r + 1), r->type);
		zane_free((char *)r, (int64_t)sizeof *r + r->size, 8);
	}
	if (m->heap.live != 0) zane_broken("a dynamic block outlived its owner");
}

/* A context whose call is over, back in the pool: the result took its
   blocks home, and its first scope's region goes as any scope's does. */
static void zane_release(zane_context *c) {
	zane_mark *m = zane_mark_at(c, 0);
	if (zane_checking) zane_check(m);
	zane_lock(c);
	zane_unmap(m);
	c->depth = 0;
	c->chunks = 0;
	c->frontier = 0;
	zane_give_spares(c);
	zane_unlock(c);
	pthread_mutex_lock(&zane_memory);
	c->next = zane_idle;
	zane_idle = c;
	pthread_mutex_unlock(&zane_memory);
}

/* Waiting for a call (§3.2): one no thread has taken yet runs here, and one
   running elsewhere is waited for. Its result then comes home, once. */
static void zane_join_task(zane_task *t) {
	if (t->owner != zane_self) zane_broken("a spawned call joined outside its context");
	if (zane_state(t) == ZANE_JOINED) return;
	zane_deque *d = &zane_deques[t->deque];
	pthread_mutex_lock(&d->lock);
	int mine = zane_state(t) == ZANE_QUEUED;
	if (mine) zane_unlink(d, t);
	pthread_mutex_unlock(&d->lock);
	if (mine) {
		zane_taken();
		zane_run(t);
	}
	pthread_mutex_lock(&zane_pool);
	while (zane_state(t) != ZANE_DONE) pthread_cond_wait(&zane_finished, &zane_pool);
	zane_set_state(t, ZANE_JOINED);
	pthread_mutex_unlock(&zane_pool);
	if (t->size) {
		memcpy(t->dest, t->frame, (size_t)t->size);
		zane_arrive(t->dest, t->type);
	}
	zane_release(t->context);
	t->owner->shared--;
}

/* A read of what a spawned call returns. */
void zane_join(char *frame) { zane_join_task((zane_task *)frame - 1); }

/* A scope ends: as the water tower has it (§4.1), it waits for every call
   it spawned, and each result comes home. Then both its regions are
   released together, in bulk (memory.md §3.2). Nothing that outlives the
   scope owns a block in them, since an escape moves its blocks out first
   (§3.5), so every block still there dies with the scope, and none is
   walked or returned on its own, unless drains are checked. */
void zane_scope_drain(int64_t scope) {
	zane_context *c = zane_self;
	if (scope != c->depth - 1 || scope == 0) zane_broken("a scope drained out of order");
	zane_mark *m = zane_mark_at(c, scope);
	for (zane_task *t = m->tasks; t; t = t->next) zane_join_task(t);
	if (zane_checking) zane_check(m);
	zane_lock(c);
	zane_unmap(m);
	c->depth--;
	c->chunks = m->chunks;
	c->frontier = m->frontier;
	zane_unlock(c);
}
