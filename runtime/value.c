#include "zane_internal.h"

/* ---------------------------------------------------------------------- */
/* Values arriving, leaving and replaced (memory.md §2.2, §3.5)           */
/* ---------------------------------------------------------------------- */

/* Whether region `r` lives as long as region `s`: it is `s`, or an
   enclosing scope of the same context, or the program's own region. A
   region of another context is taken as shorter-lived, which only costs a
   relocation that was not needed (docs/design/lowering.md §9). */
static int zane_outlives(const zane_mark *r, const zane_mark *s) {
	return r == s || r == zane_program || (r->context == s->context && r->depth <= s->depth);
}

/* Whether a block must move into `region`. When `from` is 0 the block is
   arriving where `region` holds it, and moves only when its own region
   does not outlive that one: a move whose destination outlives the blocks
   is an escape, and any other leaves them where they are (§3.5). When
   `from` is set the blocks are leaving this context's scopes from `from`
   in, which drain first. */
static int zane_leaves(const void *block, zane_mark *region, int64_t from) {
	zane_mark *r = zane_region_at(block);
	if (from == 0) return !zane_outlives(r, region);
	return r != region && r->context == zane_self && r->depth >= from;
}

/* The block that the handle or boxed member at `at` owns moves into
   `region` when it must: an equal block there takes what lives in it, and
   the old one is returned (memory.md §3.5). What lives in it is then pushed
   onto `w`, to move the blocks it owns in turn. */
static void zane_move_at(zane_work *w, char *at, const zane_position *p, zane_mark *region,
                         int64_t from) {
	switch (p->kind) {
	case ZANE_TEXT: {
		zane_text *t = (zane_text *)at;
		if (!t->room || !zane_leaves(t->bytes, region, from)) break;
		char *bytes = zane_alloc(region, t->room, 8);
		memcpy(bytes, t->bytes, (size_t)t->length);
		zane_unblock(p, (void *)t->bytes, t->room);
		t->bytes = bytes;
		break;
	}
	case ZANE_LIST: {
		zane_list *l = (zane_list *)at;
		if (!l->room || !zane_leaves(l->items, region, from)) break;
		char *items = zane_alloc(region, l->room, ZANE_LINE);
		memcpy(items, l->items, (size_t)(l->count * p->extra));
		zane_unblock(p, l->items, l->room);
		l->items = items;
		if (p->inner && p->inner[0] > 0)
			for (int64_t i = 0; i < l->count; i++)
				zane_work_push(w, (zane_job){ .at = items + i * p->extra, .layout = p->inner });
		break;
	}
	case ZANE_BOX: {
		char **box = (char **)at;
		if (!*box || !zane_leaves(*box, region, from)) break;
		char *payload = zane_alloc(region, p->extra, 8);
		memcpy(payload, *box, (size_t)p->extra);
		zane_unblock(p, *box, 0);
		*box = payload;
		if (p->inner && p->inner[0] > 0)
			zane_work_push(w, (zane_job){ .at = payload, .layout = p->inner });
		break;
	}
	}
}

/* The value at `value` is where it now lives: every block it owns that
   must move into `region` does, as `zane_leaves` decides. */
void zane_move(char *value, const int64_t *layout, zane_mark *region, int64_t from) {
	zane_work w = { 0 };
	zane_work_push(&w, (zane_job){ .at = value, .layout = layout });
	zane_job job;
	while (zane_work_pop(&w, &job)) {
		zane_position p;
		ZANE_EACH(job.layout, p) {
			if (zane_present(job.at, &p)) zane_move_at(&w, zane_at(job.at, &p), &p, region, from);
		}
	}
	zane_work_end(&w);
}

/* A value arrived at `slot`: the blocks it owns that the slot's region
   outlives move into it, which is an escape (memory.md §3.5); the rest stay
   where they are. */
void zane_arrive(char *slot, const int64_t *layout) {
	zane_move(slot, layout, zane_region_at(slot), 0);
}

/* A value leaves the scopes from `depth` in, which drain before it arrives
   anywhere: every block it owns in them moves into the scope around them
   first (§3.1). */
void zane_promote(char *value, const int64_t *layout, int64_t depth) {
	zane_move(value, layout, zane_mark_at(zane_self, depth - 1), depth);
}

/* An owner moved out of `slot`: the slot is spent, and its blocks left with
   the owner (lifetimes.md §1.6). */
void zane_vacate(char *slot, const int64_t *layout) {
	zane_position p;
	ZANE_EACH(layout, p) {
		if (!zane_present(slot, &p)) continue;
		switch (p.kind) {
		case ZANE_TEXT:
		case ZANE_LIST: {
			zane_list *l = zane_at(slot, &p);
			l->items = NULL;
			l->count = l->room = 0;
			break;
		}
		case ZANE_BOX:
			*(char **)zane_at(slot, &p) = NULL;
			break;
		}
	}
}

/* `incoming` replaces what `slot` holds, in place (memory.md §2.2): the
   replacement is written at the occupant's address, so every reference to
   the slot, or to anything inside it, observes the replacement. A boxed
   member present in both keeps its block: the incoming payload is written
   into it, recursively, and the block that brought the payload is
   returned. So no boxed member moves to a new block, however deep, and a
   reference into one keeps its address. Everything else the occupant owns
   dies, and what the replacement brought arrives. `incoming` is complete
   before this runs, so a replacement made from the occupant is safe (§2.3). */
void zane_overwrite(char *slot, char *incoming, int64_t size, const int64_t *layout) {
	zane_work w = { 0 };
	/* Each place written, in the order written, to arrive deepest first. */
	zane_work arrivals = { 0 };
	zane_work_push(&w, (zane_job){ .at = slot, .layout = layout, .incoming = incoming, .size = size });
	zane_job job;
	while (zane_work_pop(&w, &job)) {
		zane_work_push(&arrivals, (zane_job){ .at = job.at, .layout = job.layout });
		int64_t positions = job.layout ? job.layout[0] : 0;
		int64_t n = 0;
		zane_position kept[positions + 1];
		char *blocks[positions + 1];
		zane_position p;
		ZANE_EACH(job.layout, p) {
			if (!zane_present(job.at, &p)) continue;
			char *old = p.kind == ZANE_BOX ? *(char **)zane_at(job.at, &p) : NULL;
			if (old && zane_present(job.incoming, &p) && *(char **)zane_at(job.incoming, &p)) {
				kept[n] = p;
				blocks[n++] = old;
			} else {
				zane_end_at(job.at, &p);
			}
		}
		memcpy(job.at, job.incoming, (size_t)job.size);
		/* The block that brought this payload is spent once it is copied. */
		if (job.block.kind) zane_unblock(&job.block, job.incoming, 0);
		for (int64_t i = 0; i < n; i++) {
			char **at = zane_at(job.at, &kept[i]);
			zane_work_push(&w, (zane_job){ .at = blocks[i], .layout = kept[i].inner, .incoming = *at,
			                               .size = kept[i].extra, .block = kept[i] });
			*at = blocks[i];
		}
	}
	zane_work_end(&w);
	/* What each place brought arrives where that place's own block is. */
	while (zane_work_pop(&arrivals, &job)) zane_arrive(job.at, job.layout);
	zane_work_end(&arrivals);
}

/* ---------------------------------------------------------------------- */
/* Package constants (docs/design/lowering.md L16)                        */
/* ---------------------------------------------------------------------- */

/* A constant is made once, by the first context to read it. Its state is 0
   until then, the maker's context id plus one while it is being made, and
   -1 once it is. Any other reader waits for it; its maker reading it again
   is a constant made of itself. A reader checks for -1 without the lock, so
   every access to the state is atomic. */
static pthread_mutex_t zane_constants = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t zane_constant_made = PTHREAD_COND_INITIALIZER;

/* 1 when the caller is to make the constant, and 0 once it is made. */
int64_t zane_constant_begin(int64_t *state) {
	if (__atomic_load_n(state, __ATOMIC_ACQUIRE) == -1) return 0;
	int64_t self = (int64_t)zane_self->id + 1, make = 0;
	pthread_mutex_lock(&zane_constants);
	for (;;) {
		int64_t s = __atomic_load_n(state, __ATOMIC_RELAXED);
		if (s == -1) break;
		if (s == 0) {
			__atomic_store_n(state, self, __ATOMIC_RELAXED);
			make = 1;
			break;
		}
		if (s == self) {
			pthread_mutex_unlock(&zane_constants);
			zane_broken("a package constant read while it is made");
		}
		pthread_cond_wait(&zane_constant_made, &zane_constants);
	}
	pthread_mutex_unlock(&zane_constants);
	return make;
}

/* The constant at `value` is made: the blocks it owns move into the
   program's own region, which it lives in until the program ends, and
   every reader may now read it. */
void zane_constant_end(int64_t *state, char *value, const int64_t *layout) {
	if (layout) zane_move(value, layout, zane_program, 0);
	pthread_mutex_lock(&zane_constants);
	__atomic_store_n(state, -1, __ATOMIC_RELEASE);
	pthread_cond_broadcast(&zane_constant_made);
	pthread_mutex_unlock(&zane_constants);
}
