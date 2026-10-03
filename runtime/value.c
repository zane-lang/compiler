#include "zane_internal.h"

/* ---------------------------------------------------------------------- */
/* Values arriving, leaving and replaced (memory.md §3.5, §3.7, §4.5)     */
/* ---------------------------------------------------------------------- */

/* Whether a block must move into `region`: any block elsewhere when `from`
   is 0, and otherwise one in this context's scope `from` or a later one. */
static int zane_leaves(const void *block, zane_mark *region, int64_t from) {
	zane_mark *r = zane_region_at(block);
	return r != region && (from == 0 || (r->context == zane_self && r->depth >= from));
}

/* The block that the handle or boxed member at `at` owns moves into
   `region` when it is in `from` or a later scope and not there already: an
   equal block there takes what lives in it, down through the blocks it
   owns, and the old one is returned (memory.md §3.5). */
static void zane_move_at(char *at, const zane_position *p, zane_mark *region, int64_t from) {
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
		if (p->inner)
			for (int64_t i = 0; i < l->count; i++) zane_move(items + i * p->extra, p->inner, region, from);
		break;
	}
	case ZANE_BOX: {
		char **box = (char **)at;
		if (!*box || !zane_leaves(*box, region, from)) break;
		char *payload = zane_alloc(region, p->extra, 8);
		memcpy(payload, *box, (size_t)p->extra);
		zane_unblock(p, *box, 0);
		*box = payload;
		if (p->inner) zane_move(payload, p->inner, region, from);
		break;
	}
	}
}

/* The value at `value` is where it now lives: the anchors of the hosts it
   holds follow them there (§4.5), and every block it owns that is in
   `from` or a later scope moves into `region`. */
void zane_move(char *value, const int64_t *layout, zane_mark *region, int64_t from) {
	zane_position p;
	ZANE_EACH(layout, p) {
		uint32_t id;
		if (!zane_present(value, &p)) continue;
		if (p.kind != ZANE_HOST) zane_move_at(zane_at(value, &p), &p, region, from);
		else if ((id = *zane_backpointer(value, &p))) zane_anchor(id)->target = value + p.offset;
	}
}

/* A value arrived at `slot`, which had no identity: the anchors it carries
   follow it there (§4.5), and the blocks it owns move into the region of
   the scope that holds the slot. */
void zane_arrive(char *slot, const int64_t *layout) {
	zane_move(slot, layout, zane_region_at(slot), 0);
}

/* A value leaves the scopes from `depth` in, which drain before it arrives
   anywhere: every block it owns in them moves into the scope around them
   first (§3.1). */
void zane_promote(char *value, const int64_t *layout, int64_t depth) {
	zane_move(value, layout, zane_mark_at(zane_self, depth - 1), depth);
}

/* A host moved out of `slot`: the slot is spent, and its identities and
   blocks left with the host. */
void zane_vacate(char *slot, const int64_t *layout) {
	zane_position p;
	ZANE_EACH(layout, p) {
		if (!zane_present(slot, &p)) continue;
		switch (p.kind) {
		case ZANE_HOST:
			*zane_backpointer(slot, &p) = 0;
			break;
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

/* Floated hosts, and the blocks they took along when they floated, which
   stay out until the program ends. */
_Atomic int64_t zane_floated;

/* The values lent to `m` as it drains (lifetimes.md §1.5). One still inside
   it -- in a slot of its, or an element or member of something there --
   belongs to the call site, so it floats out before the drain ends it, as
   a contingent place's occupant does, and its guests follow it. One that
   has moved to a scope between this one and the caller's is now that
   scope's to bring back. One that left for the caller's scope or beyond,
   or died, needs nothing, and nor does one on its way out through a
   `return`: its anchor names the place it left, which no longer carries
   its identity, or the temporary it travels in, which no region holds. */
void zane_return_lent(zane_mark *m) {
	while (m->lent) {
		zane_lent *l = m->lent;
		m->lent = l->next;
		int dead = zane_anchor(l->id)->dead;
		char *at = dead ? NULL : zane_resolve(l->id);
		if (at && (!zane_in_region(at) || *(uint32_t *)at != zane_terminal(l->id))) dead = 1;
		if (dead) {
			zane_release_hold(l->id);
			free(l);
			continue;
		}
		zane_mark *r = zane_region_at(at);
		int above = l->origin->context != m->context || l->origin->depth < m->depth;
		int inside = above && r->context == m->context && r->depth >= m->depth;
		int between = r->context == m->context && r->depth < m->depth &&
		              (l->origin->context != m->context || l->origin->depth < r->depth);
		if (inside) {
			char *anonymous = zane_alloc(zane_program, l->size, 8);
			zane_floated += 1 + zane_owned(at, l->layout, 0, l->size);
			memcpy(anonymous, at, (size_t)l->size);
			zane_move(anonymous, l->layout, zane_program, 0);
			zane_anchor(zane_terminal(l->id))->target = anonymous;
			zane_vacate(at, l->layout);
			*(uint32_t *)at = 0;
		} else if (between) {
			zane_lock(r->context);
			l->next = r->lent;
			r->lent = l;
			zane_unlock(r->context);
			continue;
		}
		zane_release_hold(l->id);
		free(l);
	}
}

/* `incoming` replaces what `slot` holds (memory.md §3.7, §4.5). A contingent
   place's anchored occupant -- a variant payload's, or anything in a list's
   element when `contingent` is set -- first floats into an anonymous host in
   the program's own region, taking along the anchors of every host inside
   it, and its blocks, which move there too. What stays dies, and its blocks are
   returned. Then each stable host keeps its identity: the incoming one
   takes it, and an identity the incoming one brought forwards to it. A
   contingent one keeps the incoming host's own. What arrives moves its
   blocks into the slot's region. */
void zane_overwrite(char *slot, char *incoming, int64_t size, const int64_t *layout,
                    int64_t contingent) {
	zane_position p, q;
	int64_t positions = layout ? layout[0] : 0;
	int64_t n = 0, from[positions + 1], length[positions + 1];
	ZANE_EACH(layout, p) {
		uint32_t id;
		if ((p.conditions == 0 && !contingent) || !zane_hosts(slot, &p)) continue;
		if (zane_inside(p.offset, from, length, n)) continue;
		if (!(id = *zane_backpointer(slot, &p))) continue;
		/* A floated host is a block of the program's own region, so what
		   later arrives in it, or grows from it, is placed there too. It
		   lives until the program ends, and so do its blocks
		   (docs/design/lowering.md §9). */
		char *anonymous = zane_alloc(zane_program, p.size, 8);
		memcpy(anonymous, slot + p.offset, (size_t)p.size);
		zane_floated += 1 + zane_owned(slot, layout, p.offset, p.offset + p.size);
		ZANE_EACH(layout, q) {
			uint32_t inner;
			if (q.offset < p.offset || q.offset >= p.offset + p.size) continue;
			if (!zane_present(slot, &q)) continue;
			char *at = anonymous + (q.offset - p.offset);
			if (q.kind != ZANE_HOST) zane_move_at(at, &q, zane_program, 0);
			else if ((inner = *zane_backpointer(slot, &q))) zane_anchor(inner)->target = at;
		}
		from[n] = p.offset;
		length[n++] = p.size;
	}
	zane_end(slot, layout, 0, from, length, n);
	ZANE_EACH(layout, p) {
		if (!zane_hosts(incoming, &p)) continue;
		uint32_t *brought = zane_backpointer(incoming, &p);
		uint32_t kept = p.conditions == 0 && !contingent ? *zane_backpointer(slot, &p) : 0;
		if (kept) {
			if (*brought && *brought != kept) {
				pthread_mutex_lock(&zane_anchors);
				zane_anchor(*brought)->forward = kept;
				zane_anchor(*brought)->sibling = zane_anchor(kept)->forwarders;
				zane_anchor(kept)->forwarders = *brought;
				pthread_mutex_unlock(&zane_anchors);
			}
			*brought = kept;
		}
	}
	memcpy(slot, incoming, (size_t)size);
	zane_arrive(slot, layout);
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
