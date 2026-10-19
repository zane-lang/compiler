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
   in, which drain first. A type's move walk asks this of each block it
   owns: one that must move goes into an equal block in `region`, and the
   old one is returned. */
int64_t zane_leaves(const char *block, zane_mark *region, int64_t from) {
	zane_mark *r = zane_region_at(block);
	if (from == 0) return !zane_outlives(r, region);
	return r != region && r->context == zane_self && r->depth >= from;
}

/* The value at `value` is where it now lives: every block it owns that
   must move into `region` does, as `zane_leaves` decides. */
void zane_move(char *value, const zane_type *type, zane_mark *region, int64_t from) {
	if (!type) return;
	zane_work w;
	zane_work_start(&w);
	type->move(value, (char *)region, from, &w, 0);
	zane_work_run(&w);
}

/* A value arrived at `slot`: the blocks it owns that the slot's region
   outlives move into it, which is an escape (memory.md §3.5); the rest stay
   where they are. */
void zane_arrive(char *slot, const zane_type *type) {
	if (type) zane_move(slot, type, zane_region_at(slot), 0);
}

/* A value leaves the scopes from `scope` in, which drain before it arrives
   anywhere: every block it owns in them moves into the scope around them
   first (§3.1). */
void zane_promote(char *value, const zane_type *type, zane_mark *scope) {
	if (!type) return;
	zane_move(value, type, scope->outer, scope->depth);
}

/* `incoming` replaces what `slot` holds, in place (memory.md §2.2): the
   replacement is written at the occupant's address, so every reference to
   the slot, or to anything inside it, observes the replacement. A boxed
   member present in both keeps its block: the incoming payload is written
   into it, recursively, and the block that brought the payload is
   returned. So no boxed member moves to a new block, however deep, and a
   reference into one keeps its address. Everything else the occupant owns
   dies, and what the replacement brought arrives: each place written hands
   on its arrival before anything below it is written, so the deepest
   arrive first. `incoming` is complete before this runs, so a replacement
   made from the occupant is safe (§2.3). */
void zane_overwrite(char *slot, char *incoming, int64_t size, const zane_type *type) {
	if (!type) {
		memcpy(slot, incoming, (size_t)size);
		return;
	}
	zane_work w;
	zane_work_start(&w);
	type->overwrite(slot, incoming, size, &w, 0);
	zane_work_run(&w);
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

/* The graph of waits. A context about to block names what it waits for: a
   constant's state, whose maker it waits for while the constant is made,
   or a call it joins, whose context it waits for while the call runs. Each
   edge is read from what it names when it is followed, so it never outlives
   its wait: a made constant or a finished call leads nowhere, and a call
   not yet given its context leads nowhere yet. Edges are set, cleared and
   followed under one lock, so of the waits that close a cycle, the last
   finds it, by following the edges from itself back to itself. Contexts
   are reused, never freed, and each names at most one thing. */
static pthread_mutex_t zane_waits = PTHREAD_MUTEX_INITIALIZER;

/* A cycle of waits is the program's error, as an index out of range is: a
   program reaches it when making a constant spawns a call that reads,
   through any chain, the constant being made. */
_Noreturn static void zane_constant_cycle(void) {
	zane_flush_output();
	fputs("package constants read each other while they are made\n", stderr);
	exit(1);
}

static zane_context *zane_waited_on(zane_context *c) {
	if (c->awaits) {
		int64_t s = __atomic_load_n(c->awaits, __ATOMIC_ACQUIRE);
		return s > 0 ? zane_context_at((int32_t)(s - 1)) : NULL;
	}
	zane_task *t = c->joins;
	if (t && zane_state(t) < ZANE_DONE) return __atomic_load_n(&t->context, __ATOMIC_ACQUIRE);
	return NULL;
}

/* This context waits for the constant whose state is `constant`, or for
   `call`; a wait that leads back to it stops the program. */
void zane_wait_for(int64_t *constant, zane_task *call) {
	zane_context *self = zane_self;
	pthread_mutex_lock(&zane_waits);
	self->awaits = constant;
	self->joins = call;
	int32_t steps = __atomic_load_n(&zane_context_count, __ATOMIC_ACQUIRE);
	for (zane_context *c = zane_waited_on(self); c && steps-- > 0; c = zane_waited_on(c))
		if (c == self) {
			pthread_mutex_unlock(&zane_waits);
			zane_constant_cycle();
		}
	pthread_mutex_unlock(&zane_waits);
}

/* This context waits no longer. */
void zane_waited(void) {
	pthread_mutex_lock(&zane_waits);
	zane_self->awaits = NULL;
	zane_self->joins = NULL;
	pthread_mutex_unlock(&zane_waits);
}

/* 1 when the caller is to make the constant, and 0 once it is made. */
int64_t zane_constant_begin(int64_t *state) {
	if (__atomic_load_n(state, __ATOMIC_ACQUIRE) == -1) return 0;
	int64_t self = (int64_t)zane_self->id + 1, make = 0;
	int waited = 0;
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
		if (!waited) {
			zane_wait_for(state, NULL);
			waited = 1;
		}
		pthread_cond_wait(&zane_constant_made, &zane_constants);
	}
	pthread_mutex_unlock(&zane_constants);
	if (waited) zane_waited();
	return make;
}

/* The constant at `value` is made: the blocks it owns move into the
   program's own region, which it lives in until the program ends, and
   every reader may now read it. */
void zane_constant_end(int64_t *state, char *value, const zane_type *type) {
	zane_move(value, type, zane_program, 0);
	pthread_mutex_lock(&zane_constants);
	__atomic_store_n(state, -1, __ATOMIC_RELEASE);
	pthread_cond_broadcast(&zane_constant_made);
	pthread_mutex_unlock(&zane_constants);
}
