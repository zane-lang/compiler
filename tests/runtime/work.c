/* The walks that copy, move, overwrite and end a value, at the widths and
   depths where their work outgrows the few jobs it keeps in itself and takes
   a heap buffer, over hand-written layouts. Each check prints `yes` when it
   holds and `no` when it does not. */

#include "zane_internal.h"

#include <stddef.h>

static void check(int ok) { puts(ok ? "yes" : "no"); }

/* A list of strings, and a value that boxes itself:
   `variant { done Unit; more Countdown; }`. */
typedef struct {
	int32_t tag;
	char *more;
} countdown;

static const int64_t text_layout[] = {
	1,
	ZANE_TEXT, 0, sizeof(zane_text), 0, 0, 0,
};
static int64_t texts_layout[] = {
	1,
	ZANE_LIST, 0, sizeof(zane_list), sizeof(zane_text), 0, 0,
};
static int64_t countdown_layout[] = {
	1,
	ZANE_BOX, offsetof(countdown, more), sizeof(char *), sizeof(countdown), 0, 1,
	offsetof(countdown, tag), 1,
};

/* A countdown `n` boxes deep, every box in the current scope's region. */
static countdown chain(int64_t n) {
	countdown head = { 0, NULL };
	for (int64_t i = 0; i < n; i++) {
		countdown *box = zane_box(sizeof(countdown), 8);
		*box = head;
		head = (countdown){ 1, (char *)box };
	}
	return head;
}

static int64_t depth(const countdown *c) {
	int64_t n = 0;
	for (; c->tag == 1; c = (const countdown *)c->more) n++;
	return n;
}

/* Whether no box of `a` is a box of `b`, walking both together. */
static int apart(const countdown *a, const countdown *b) {
	for (; a->tag == 1 && b->tag == 1; a = (countdown *)a->more, b = (countdown *)b->more)
		if (a->more == b->more) return 0;
	return 1;
}

void zane_main(void) {
	texts_layout[1 + 4] = (int64_t)(intptr_t)text_layout;
	countdown_layout[1 + 4] = (int64_t)(intptr_t)countdown_layout;

	/* A copy of a list of twenty strings queues a job per string, more
	   than a walk keeps in itself, and every string still gets a block of
	   its own. */
	int64_t scope = zane_scope_enter();
	zane_list *words = zane_slot(scope, sizeof(zane_list), 8, texts_layout);
	zane_list_new(words);
	zane_text ab = { "ab", 2, 0 };
	for (int i = 0; i < 20; i++) zane_text_join(zane_list_push(words, sizeof(zane_text)), &ab, &ab);
	check(zane_blocks == 21);
	zane_list *copied = zane_slot(scope, sizeof(zane_list), 8, texts_layout);
	*copied = *words;
	zane_copy((char *)copied, texts_layout);
	int same = 0, equal = 1;
	for (int64_t i = 1; i <= 20; i++) {
		zane_text *w = zane_list_at(words, i, sizeof(zane_text));
		zane_text *c = zane_list_at(copied, i, sizeof(zane_text));
		same += w->bytes == c->bytes;
		equal &= c->length == 4 && memcmp(c->bytes, "abab", 4) == 0;
	}
	check(same == 0 && equal && zane_blocks == 42);

	/* Ending it returns all twenty-one blocks, the list's last. */
	zane_end((char *)words, texts_layout);
	*words = (zane_list){ NULL, 0, 0 };
	check(zane_blocks == 21);

	/* Moving it out of an inner scope takes each string's block along. */
	int64_t inner = zane_scope_enter();
	zane_list young;
	zane_list_new(&young);
	for (int i = 0; i < 20; i++) zane_text_join(zane_list_push(&young, sizeof(zane_text)), &ab, &ab);
	zane_promote((char *)&young, texts_layout, inner);
	zane_scope_drain(inner);
	int moved = 1;
	for (int64_t i = 1; i <= 20; i++)
		moved &= zane_region_at(((zane_text *)zane_list_at(&young, i, sizeof(zane_text)))->bytes)->depth == scope;
	check(moved && zane_region_at(young.items)->depth == scope);
	zane_list *kept = zane_slot(scope, sizeof(zane_list), 8, texts_layout);
	*kept = young;
	zane_scope_drain(scope);
	check(zane_blocks == 0);

	/* An overwrite of one countdown by another keeps every box of the
	   occupant where it is, and records more places to arrive than a walk
	   keeps in itself. */
	scope = zane_scope_enter();
	countdown *a = zane_slot(scope, sizeof(countdown), 8, countdown_layout);
	*a = chain(10);
	countdown *second = (countdown *)a->more;
	countdown incoming = chain(12);
	check(zane_blocks == 22);
	zane_overwrite((char *)a, (char *)&incoming, sizeof(countdown), countdown_layout);
	check(depth(a) == 12 && (countdown *)a->more == second && zane_blocks == 12);
	zane_scope_drain(scope);
	check(zane_blocks == 0);

	/* A countdown a hundred thousand boxes deep is copied, compared and
	   ended in loops, with no depth limit. */
	scope = zane_scope_enter();
	countdown *deep = zane_slot(scope, sizeof(countdown), 8, countdown_layout);
	*deep = chain(100000);
	countdown *twin = zane_slot(scope, sizeof(countdown), 8, countdown_layout);
	*twin = *deep;
	zane_copy((char *)twin, countdown_layout);
	check(depth(twin) == 100000 && apart(deep, twin) && zane_blocks == 200000);
	zane_end((char *)deep, countdown_layout);
	*deep = (countdown){ 0, NULL };
	check(depth(twin) == 100000 && zane_blocks == 100000);
	zane_scope_drain(scope);
	check(zane_blocks == 0);
}
