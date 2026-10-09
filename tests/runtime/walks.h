/* The walks the compiler emits for each type that owns blocks
   (lib/codegen/walks.ml), written by hand in C for the types the runtime's
   tests hold: a string, a list, a box, and the types made of them. Each
   follows what lib/codegen/walks.ml emits, so the runtime's own parts --
   its regions, its work, its copy, end, move and overwrite -- are tested
   with walks of the same shape as a program's. */

#ifndef ZANE_TEST_WALKS_H
#define ZANE_TEST_WALKS_H

#include "zane_internal.h"

/* How many walks deep a walk calls the next itself. */
#define DEEPEST 256

/* A nested value's walk: called here, one deeper, or handed on. */
static inline void visit(zane_walk walk, char *at, char *with, int64_t extra, zane_work *w, int64_t depth) {
	if (depth < DEEPEST) walk(at, with, extra, w, depth + 1);
	else zane_defer(w, walk, at, with, extra);
}

/* A string. */
static inline void text_copy(zane_text *t, zane_mark *region) {
	if (!t->room) return;
	char *bytes = zane_alloc_held(region, t->length, 8);
	memcpy(bytes, t->bytes, (size_t)t->length);
	t->bytes = bytes;
	t->room = t->length;
}

static inline void text_end(zane_text *t) {
	if (t->room) zane_free((char *)t->bytes, t->room, 8);
	*t = (zane_text){ NULL, 0, 0 };
}

static inline void text_move(zane_text *t, zane_mark *region, int64_t from) {
	if (!t->room || !zane_leaves(t->bytes, region, from)) return;
	char *bytes = zane_alloc(region, t->room, 8);
	memcpy(bytes, t->bytes, (size_t)t->length);
	zane_free((char *)t->bytes, t->room, 8);
	t->bytes = bytes;
}

/* A list of elements `stride` bytes apart, whose walks are `elements`, or
   none when they own no blocks. */
static inline void list_copy(zane_list *l, zane_mark *region, int64_t stride, const zane_type *elements,
                      zane_work *w, int64_t depth) {
	if (!l->room) return;
	char *items = zane_alloc_held(region, l->room, ZANE_LINE);
	memcpy(items, l->items, (size_t)(l->count * stride));
	l->items = items;
	if (elements)
		for (int64_t i = 0; i < l->count; i++)
			visit(elements->copy, items + i * stride, (char *)region, 0, w, depth);
}

static inline void list_end(zane_list *l, int64_t stride, const zane_type *elements, zane_work *w,
                     int64_t depth) {
	if (elements && depth >= DEEPEST) {
		if (l->room) zane_defer_return(w, l->items, l->room, ZANE_LINE);
		for (int64_t i = 0; i < l->count; i++)
			zane_defer(w, elements->end, l->items + i * stride, NULL, 0);
	} else {
		if (elements)
			for (int64_t i = 0; i < l->count; i++)
				elements->end(l->items + i * stride, NULL, 0, w, depth + 1);
		if (l->room) zane_free(l->items, l->room, ZANE_LINE);
	}
	*l = (zane_list){ NULL, 0, 0 };
}

static inline void list_move(zane_list *l, zane_mark *region, int64_t from, int64_t stride,
                      const zane_type *elements, zane_work *w, int64_t depth) {
	if (!l->room || !zane_leaves(l->items, region, from)) return;
	char *items = zane_alloc(region, l->room, ZANE_LINE);
	memcpy(items, l->items, (size_t)(l->count * stride));
	zane_free(l->items, l->room, ZANE_LINE);
	l->items = items;
	if (elements)
		for (int64_t i = 0; i < l->count; i++)
			visit(elements->move, items + i * stride, (char *)region, from, w, depth);
}

/* A box holding `size` bytes, whose walks are `payload`, or none. */
static inline void box_copy(char **box, zane_mark *region, int64_t size, const zane_type *payload,
                     zane_work *w, int64_t depth) {
	if (!*box) return;
	char *fresh = zane_alloc_held(region, size, 8);
	memcpy(fresh, *box, (size_t)size);
	*box = fresh;
	if (payload) visit(payload->copy, fresh, (char *)region, 0, w, depth);
}

static inline void box_end(char **box, int64_t size, const zane_type *payload, zane_work *w, int64_t depth) {
	if (*box) {
		if (!payload) {
			zane_free(*box, size, 8);
		} else if (depth < DEEPEST) {
			payload->end(*box, NULL, 0, w, depth + 1);
			zane_free(*box, size, 8);
		} else {
			zane_defer_return(w, *box, size, 8);
			zane_defer(w, payload->end, *box, NULL, 0);
		}
	}
	*box = NULL;
}

static inline void box_move(char **box, zane_mark *region, int64_t from, int64_t size,
                     const zane_type *payload, zane_work *w, int64_t depth) {
	if (!*box || !zane_leaves(*box, region, from)) return;
	char *fresh = zane_alloc(region, size, 8);
	memcpy(fresh, *box, (size_t)size);
	zane_free(*box, size, 8);
	*box = fresh;
	if (payload) visit(payload->move, fresh, (char *)region, from, w, depth);
}

/* The box at `box` after an overwrite wrote the replacement's bytes over
   it, when the occupant's was `kept`: the occupant's block stays, and the
   replacement's payload is written into it. */
static inline void box_keep(char **box, char *kept, int64_t size, const zane_type *payload, zane_work *w,
                     int64_t depth) {
	char *incoming = *box;
	*box = kept;
	if (!payload) {
		memcpy(kept, incoming, (size_t)size);
		zane_free(incoming, size, 8);
	} else if (depth < DEEPEST) {
		payload->overwrite(kept, incoming, size, w, depth + 1);
		zane_free(incoming, size, 8);
	} else {
		zane_defer_return(w, incoming, size, 8);
		zane_defer(w, payload->overwrite, kept, incoming, size);
	}
}

/* The arrival an overwrite hands on first. */
static inline void arrival(zane_walk move, char *at, zane_work *w) {
	zane_defer(w, move, at, (char *)zane_region_at(at), 0);
}

/* `String`. */
static inline void text_copy_walk(char *at, char *with, int64_t extra, zane_work *w, int64_t depth) {
	(void)extra, (void)w, (void)depth;
	text_copy((zane_text *)at, (zane_mark *)with);
}

static inline void text_end_walk(char *at, char *with, int64_t extra, zane_work *w, int64_t depth) {
	(void)with, (void)extra, (void)w, (void)depth;
	text_end((zane_text *)at);
}

static inline void text_move_walk(char *at, char *with, int64_t extra, zane_work *w, int64_t depth) {
	(void)w, (void)depth;
	text_move((zane_text *)at, (zane_mark *)with, extra);
}

static inline void text_overwrite_walk(char *at, char *with, int64_t extra, zane_work *w, int64_t depth) {
	(void)depth;
	arrival(text_move_walk, at, w);
	text_end((zane_text *)at);
	memcpy(at, with, (size_t)extra);
}

__attribute__((unused)) static const zane_type text_type = { text_copy_walk, text_end_walk, text_move_walk, text_overwrite_walk };

/* `List<String>`. */
static inline void texts_copy_walk(char *at, char *with, int64_t extra, zane_work *w, int64_t depth) {
	(void)extra;
	list_copy((zane_list *)at, (zane_mark *)with, sizeof(zane_text), &text_type, w, depth);
}

static inline void texts_end_walk(char *at, char *with, int64_t extra, zane_work *w, int64_t depth) {
	(void)with, (void)extra;
	list_end((zane_list *)at, sizeof(zane_text), &text_type, w, depth);
}

static inline void texts_move_walk(char *at, char *with, int64_t extra, zane_work *w, int64_t depth) {
	list_move((zane_list *)at, (zane_mark *)with, extra, sizeof(zane_text), &text_type, w, depth);
}

static inline void texts_overwrite_walk(char *at, char *with, int64_t extra, zane_work *w, int64_t depth) {
	arrival(texts_move_walk, at, w);
	list_end((zane_list *)at, sizeof(zane_text), &text_type, w, depth);
	memcpy(at, with, (size_t)extra);
}

__attribute__((unused)) static const zane_type texts_type = { texts_copy_walk, texts_end_walk, texts_move_walk,
	                                  texts_overwrite_walk };

/* `variant { done Unit; more Countdown; }`, which boxes itself. */
typedef struct {
	int32_t tag;
	char *more;
} countdown;

static const zane_type countdown_type;

static inline void countdown_copy_walk(char *at, char *with, int64_t extra, zane_work *w, int64_t depth) {
	(void)extra;
	countdown *c = (countdown *)at;
	if (c->tag == 1) box_copy(&c->more, (zane_mark *)with, sizeof(countdown), &countdown_type, w, depth);
}

static inline void countdown_end_walk(char *at, char *with, int64_t extra, zane_work *w, int64_t depth) {
	(void)with, (void)extra;
	countdown *c = (countdown *)at;
	if (c->tag == 1) box_end(&c->more, sizeof(countdown), &countdown_type, w, depth);
}

static inline void countdown_move_walk(char *at, char *with, int64_t extra, zane_work *w, int64_t depth) {
	countdown *c = (countdown *)at;
	if (c->tag == 1) box_move(&c->more, (zane_mark *)with, extra, sizeof(countdown), &countdown_type, w, depth);
}

static inline void countdown_overwrite_walk(char *at, char *with, int64_t extra, zane_work *w, int64_t depth) {
	countdown *c = (countdown *)at, *in = (countdown *)with;
	arrival(countdown_move_walk, at, w);
	char *kept = NULL;
	if (c->tag == 1) {
		if (c->more && in->tag == 1 && in->more) kept = c->more;
		else box_end(&c->more, sizeof(countdown), &countdown_type, w, depth);
	}
	memcpy(at, with, (size_t)extra);
	if (kept) box_keep(&c->more, kept, sizeof(countdown), &countdown_type, w, depth);
}

__attribute__((unused)) static const zane_type countdown_type = { countdown_copy_walk, countdown_end_walk, countdown_move_walk,
	                                      countdown_overwrite_walk };

/* `List<Int>` and a box of an `Int`: what they hold owns no blocks. */
static inline void ints_copy_walk(char *at, char *with, int64_t extra, zane_work *w, int64_t depth) {
	(void)extra;
	list_copy((zane_list *)at, (zane_mark *)with, sizeof(int64_t), NULL, w, depth);
}

static inline void ints_end_walk(char *at, char *with, int64_t extra, zane_work *w, int64_t depth) {
	(void)with, (void)extra;
	list_end((zane_list *)at, sizeof(int64_t), NULL, w, depth);
}

static inline void ints_move_walk(char *at, char *with, int64_t extra, zane_work *w, int64_t depth) {
	list_move((zane_list *)at, (zane_mark *)with, extra, sizeof(int64_t), NULL, w, depth);
}

static inline void ints_overwrite_walk(char *at, char *with, int64_t extra, zane_work *w, int64_t depth) {
	arrival(ints_move_walk, at, w);
	list_end((zane_list *)at, sizeof(int64_t), NULL, w, depth);
	memcpy(at, with, (size_t)extra);
}

__attribute__((unused)) static const zane_type ints_type = { ints_copy_walk, ints_end_walk, ints_move_walk, ints_overwrite_walk };

static inline void boxed_int_copy_walk(char *at, char *with, int64_t extra, zane_work *w, int64_t depth) {
	(void)extra;
	box_copy((char **)at, (zane_mark *)with, sizeof(int64_t), NULL, w, depth);
}

static inline void boxed_int_end_walk(char *at, char *with, int64_t extra, zane_work *w, int64_t depth) {
	(void)with, (void)extra;
	box_end((char **)at, sizeof(int64_t), NULL, w, depth);
}

static inline void boxed_int_move_walk(char *at, char *with, int64_t extra, zane_work *w, int64_t depth) {
	box_move((char **)at, (zane_mark *)with, extra, sizeof(int64_t), NULL, w, depth);
}

static inline void boxed_int_overwrite_walk(char *at, char *with, int64_t extra, zane_work *w, int64_t depth) {
	char **box = (char **)at, **in = (char **)with;
	arrival(boxed_int_move_walk, at, w);
	char *kept = NULL;
	if (*box && *in) kept = *box;
	else box_end(box, sizeof(int64_t), NULL, w, depth);
	memcpy(at, with, (size_t)extra);
	if (kept) box_keep(box, kept, sizeof(int64_t), NULL, w, depth);
}

__attribute__((unused)) static const zane_type boxed_int_type = { boxed_int_copy_walk, boxed_int_end_walk, boxed_int_move_walk,
	                                      boxed_int_overwrite_walk };

#endif
