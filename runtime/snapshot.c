#include "zane_internal.h"

/* ---------------------------------------------------------------------- */
/* Snapshots (concurrency.md §4.4, docs/design/lowering.md §9)                   */
/* ---------------------------------------------------------------------- */

/* A spawned `mut` call whose subject is reached through a host works on a
   copy of its own, and writes it back when it returns. A write-back counts
   itself begun, replaces the bytes, and counts itself done; a reader of a
   value reached through a host takes its bytes when every write-back begun
   is done, and keeps them when none began while it read. The bytes move a
   word at a time, as atomics, so a read is torn only where it is retried. */
static uint64_t zane_begun, zane_done;

static void zane_racy_copy(char *to, const char *from, int64_t size, int store) {
	int64_t i = 0;
	if (((uintptr_t)to | (uintptr_t)from) % 8 == 0)
		for (; i + 8 <= size; i += 8) {
			uint64_t *word = (uint64_t *)(to + i);
			const uint64_t *source = (const uint64_t *)(from + i);
			if (store) __atomic_store_n(word, *source, __ATOMIC_RELAXED);
			else *word = __atomic_load_n(source, __ATOMIC_RELAXED);
		}
	for (; i < size; i++) {
		if (store) __atomic_store_n(to + i, from[i], __ATOMIC_RELAXED);
		else to[i] = __atomic_load_n(from + i, __ATOMIC_RELAXED);
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
		zane_racy_copy(out, from, size, 0);
		__atomic_thread_fence(__ATOMIC_ACQUIRE);
		if (__atomic_load_n(&zane_begun, __ATOMIC_RELAXED) == begun) return;
	}
}

/* The copy a spawned call worked on replaces its subject at `at`. What the
   copy owns moves into the subject's region first, and what the subject
   owned is retired there, whole, until the region drains. */
void zane_writeback(char *at, char *copy, int64_t size, const int64_t *layout) {
	zane_mark *region = zane_region_at(at);
	if (layout && layout[0] > 0) {
		zane_move(copy, layout, region, 0);
		zane_retired *r = (zane_retired *)zane_alloc(region, (int64_t)sizeof *r + size, 8);
		memcpy(r + 1, at, (size_t)size);
		r->layout = layout;
		r->size = size;
		zane_lock(region->context);
		r->next = region->retired;
		region->retired = r;
		zane_unlock(region->context);
	}
	__atomic_fetch_add(&zane_begun, 1, __ATOMIC_RELAXED);
	__atomic_thread_fence(__ATOMIC_RELEASE);
	zane_racy_copy(at, copy, size, 1);
	__atomic_fetch_add(&zane_done, 1, __ATOMIC_RELEASE);
}

/* A draining region's retired values end, and their records go back. */
static void zane_forget(zane_mark *m) {
	while (m->retired) {
		zane_retired *r = m->retired;
		m->retired = r->next;
		zane_end((char *)(r + 1), r->layout, 1, NULL, NULL, 0);
		zane_free((char *)r, (int64_t)sizeof *r + r->size, 8);
	}
}

/* A context whose call is over, back in the pool: by now its first scope
   holds nothing, since the result took its blocks home. */
static void zane_release(zane_context *c) {
	zane_mark *m = zane_mark_at(c, 0);
	zane_return_lent(m);
	for (zane_hosted *h = m->hosts; h; h = h->next) zane_end(h->slot, h->layout, 1, NULL, NULL, 0);
	zane_forget(m);
	zane_lock(c);
	if (m->live != 0) zane_broken("a dynamic block outlived its owner");
	zane_unmap(m);
	c->depth = 0;
	c->chunks = 0;
	c->frontier = 0;
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
		zane_arrive(t->dest, t->layout);
	}
	zane_release(t->context);
	t->owner->shared--;
}

/* A read of what a spawned call returns. */
void zane_join(char *frame) { zane_join_task((zane_task *)frame - 1); }

/* Every identity the scope still hosts ends: its anchors, and the
   forwarders to them, retire. The blocks its values still own are
   returned, and by then no block is out in its region, since every one has
   an owner in the scope or has moved out with it. Then both regions are
   released together. First, as the water tower has it (§4.1), the scope
   waits for every call it spawned, and each result comes home. */
void zane_scope_drain(int64_t scope) {
	zane_context *c = zane_self;
	if (scope != c->depth - 1 || scope == 0) zane_broken("a scope drained out of order");
	zane_mark *m = zane_mark_at(c, scope);
	for (zane_task *t = m->tasks; t; t = t->next) zane_join_task(t);
	zane_return_lent(m);
	for (zane_hosted *h = m->hosts; h; h = h->next) zane_end(h->slot, h->layout, 1, NULL, NULL, 0);
	zane_forget(m);
	zane_lock(c);
	if (m->live != 0) zane_broken("a dynamic block outlived its owner");
	zane_unmap(m);
	c->depth--;
	c->chunks = m->chunks;
	c->frontier = m->frontier;
	zane_unlock(c);
}
