#include "zane_internal.h"

/* ---------------------------------------------------------------------- */
/* Dynamic blocks (memory.md §3.6, docs/design/lowering.md §9)                   */
/* ---------------------------------------------------------------------- */

/* A block is returned when the handle or boxed member that owns it dies,
   to the region it is in. What it is decides its size and alignment: a
   string's bytes are as long as its room, a list's elements start at a
   cache line (memory.md §3.6), and a box holds one payload. */
void zane_unblock(const zane_position *p, void *block, int64_t room) {
	zane_free(block, p->kind == ZANE_BOX ? p->extra : room, p->kind == ZANE_LIST ? ZANE_LINE : 8);
}

void *zane_at(char *base, const zane_position *p) { return base + p->offset; }

/* Whether `offset` is inside one of the `n` hosts that start at `from`,
   each `size` bytes long. */
int zane_inside(int64_t offset, const int64_t *from, const int64_t *size, int64_t n) {
	for (int64_t i = 0; i < n; i++)
		if (offset >= from[i] && offset < from[i] + size[i]) return 1;
	return 0;
}

/* The value at `base` dies, but for the `n` hosts at `from` that floated:
   each block it owns is returned, once what lives in the block has died,
   and each host inside a block ends its identity. `identities` says whether
   the hosts held inline end theirs too, as at a drain, or are the caller's
   to keep or float, as at an overwrite. */
void zane_end(char *base, const int64_t *layout, int identities, const int64_t *from,
              const int64_t *length, int64_t n) {
	zane_position p;
	ZANE_EACH(layout, p) {
		if (!zane_present(base, &p) || zane_inside(p.offset, from, length, n)) continue;
		switch (p.kind) {
		case ZANE_HOST: {
			uint32_t id = *zane_backpointer(base, &p);
			if (identities && id) zane_retire(id);
			break;
		}
		case ZANE_TEXT: {
			zane_text *t = zane_at(base, &p);
			if (t->room) zane_unblock(&p, (void *)t->bytes, t->room);
			t->bytes = NULL;
			t->length = t->room = 0;
			break;
		}
		case ZANE_LIST: {
			zane_list *l = zane_at(base, &p);
			if (p.inner)
				for (int64_t i = 0; i < l->count; i++)
					zane_end(l->items + i * p.extra, p.inner, 1, NULL, NULL, 0);
			if (l->room) zane_unblock(&p, l->items, l->room);
			l->items = NULL;
			l->count = l->room = 0;
			break;
		}
		case ZANE_BOX: {
			char **box = zane_at(base, &p);
			if (!*box) break;
			if (p.inner) zane_end(*box, p.inner, 1, NULL, NULL, 0);
			zane_unblock(&p, *box, 0);
			*box = NULL;
			break;
		}
		}
	}
}

/* How many blocks the value at `base` owns, down through them, counting
   only positions from `lo` up to `hi`. */
int64_t zane_owned(char *base, const int64_t *layout, int64_t lo, int64_t hi) {
	int64_t n = 0;
	zane_position p;
	ZANE_EACH(layout, p) {
		if (p.offset < lo || p.offset >= hi || !zane_present(base, &p)) continue;
		if (p.kind == ZANE_TEXT) {
			n += ((zane_text *)zane_at(base, &p))->room != 0;
		} else if (p.kind == ZANE_LIST) {
			zane_list *l = zane_at(base, &p);
			if (p.inner)
				for (int64_t i = 0; i < l->count; i++)
					n += zane_owned(l->items + i * p.extra, p.inner, 0, INT64_MAX);
			n += l->room != 0;
		} else if (p.kind == ZANE_BOX) {
			char *box = *(char **)zane_at(base, &p);
			if (box && p.inner) n += zane_owned(box, p.inner, 0, INT64_MAX);
			n += box != NULL;
		}
	}
	return n;
}

/* The scope a value is made in is the innermost; where it arrives decides
   where its blocks end up. */
static zane_mark *zane_here(void) { return zane_mark_at(zane_self, zane_self->depth - 1); }

/* The value at `value` was copied from another place: each block it names
   is still the original's, so it gets a copy of its own, down through the
   blocks inside it, and each host in it starts untethered (memory.md
   §2.3). */
void zane_copy(char *value, const int64_t *layout) {
	zane_position p;
	ZANE_EACH(layout, p) {
		if (!zane_present(value, &p)) continue;
		switch (p.kind) {
		case ZANE_HOST:
			*zane_backpointer(value, &p) = 0;
			break;
		case ZANE_TEXT: {
			zane_text *t = zane_at(value, &p);
			if (!t->room) break;
			char *bytes = zane_alloc(zane_here(), t->length, 8);
			memcpy(bytes, t->bytes, (size_t)t->length);
			t->bytes = bytes;
			t->room = t->length;
			break;
		}
		case ZANE_LIST: {
			zane_list *l = zane_at(value, &p);
			if (!l->room) break;
			char *items = zane_alloc(zane_here(), l->room, ZANE_LINE);
			memcpy(items, l->items, (size_t)(l->count * p.extra));
			l->items = items;
			if (p.inner)
				for (int64_t i = 0; i < l->count; i++) zane_copy(items + i * p.extra, p.inner);
			break;
		}
		case ZANE_BOX: {
			char **box = zane_at(value, &p);
			if (!*box) break;
			char *payload = zane_alloc(zane_here(), p.extra, 8);
			memcpy(payload, *box, (size_t)p.extra);
			*box = payload;
			if (p.inner) zane_copy(payload, p.inner);
			break;
		}
		}
	}
}

/* A boxed member's block (memory.md §3.6): exactly one payload's size. */
void *zane_box(int64_t size, int64_t align) { return zane_alloc(zane_here(), size, align); }

/* `@runtime$Console`'s `print` (effects.md §6.6): exactly the string's
   length in bytes, with no terminator and nothing added. */
void zane_print(const zane_text *text) {
	fwrite(text->bytes, 1, (size_t)text->length, stdout);
}

/* `+` on `@primitives$String`: a new string that owns its bytes. */
void zane_text_join(zane_text *out, const zane_text *left, const zane_text *right) {
	int64_t length = left->length + right->length;
	if (length == 0) {
		*out = (zane_text){ 0, "", 0, 0 };
		return;
	}
	char *bytes = zane_alloc(zane_here(), length, 8);
	memcpy(bytes, left->bytes, (size_t)left->length);
	memcpy(bytes + left->length, right->bytes, (size_t)right->length);
	*out = (zane_text){ 0, bytes, length, length };
}

/* `==` on `@primitives$String`: the same bytes. */
int64_t zane_text_equal(const zane_text *left, const zane_text *right) {
	return left->length == right->length &&
	       memcmp(left->bytes, right->bytes, (size_t)left->length) == 0;
}
