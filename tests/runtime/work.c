/* The walks that copy, move, overwrite and end a value, at the widths and
   depths where they hand walks on, more than a work keeps in itself, and
   the work takes a heap buffer, over hand-written walks. Each check prints
   `yes` when it holds and `no` when it does not. */

#include "walks.h"

static void check(int ok) { puts(ok ? "yes" : "no"); }

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
		
	/* A copy of a list of twenty strings gives every string a block of its
	   own. */
	zane_mark *scope = zane_scope_enter(0);
	zane_list *words = test_slot(scope, sizeof(zane_list), 8, &texts_type);
	zane_list_new(words);
	zane_text ab = { "ab", 2, 0 };
	for (int i = 0; i < 20; i++) zane_text_join(zane_list_push(words, sizeof(zane_text)), &ab, &ab);
	check(zane_blocks() == 21);
	zane_list *copied = test_slot(scope, sizeof(zane_list), 8, &texts_type);
	*copied = *words;
	zane_copy((char *)copied, &texts_type);
	int same = 0, equal = 1;
	for (int64_t i = 1; i <= 20; i++) {
		zane_text *w = zane_list_at(words, i, sizeof(zane_text));
		zane_text *c = zane_list_at(copied, i, sizeof(zane_text));
		same += w->bytes == c->bytes;
		equal &= c->length == 4 && memcmp(c->bytes, "abab", 4) == 0;
	}
	check(same == 0 && equal && zane_blocks() == 42);

	/* Ending it returns all twenty-one blocks, the list's last. */
	zane_end((char *)words, &texts_type);
	*words = (zane_list){ NULL, 0, 0 };
	check(zane_blocks() == 21);

	/* Moving it out of an inner scope takes each string's block along. */
	zane_mark *inner = zane_scope_enter(0);
	zane_list young;
	zane_list_new(&young);
	for (int i = 0; i < 20; i++) zane_text_join(zane_list_push(&young, sizeof(zane_text)), &ab, &ab);
	zane_promote((char *)&young, &texts_type, inner);
	zane_scope_drain(inner);
	int moved = 1;
	for (int64_t i = 1; i <= 20; i++)
		moved &= zane_region_at(((zane_text *)zane_list_at(&young, i, sizeof(zane_text)))->bytes) == scope;
	check(moved && zane_region_at(young.items) == scope);
	zane_list *kept = test_slot(scope, sizeof(zane_list), 8, &texts_type);
	*kept = young;
	zane_scope_drain(scope);
	check(zane_blocks() == 0);

	/* An overwrite of one countdown by another keeps every box of the
	   occupant where it is, and hands on more arrivals than a work keeps in
	   itself. */
	scope = zane_scope_enter(0);
	countdown *a = test_slot(scope, sizeof(countdown), 8, &countdown_type);
	*a = chain(10);
	countdown *second = (countdown *)a->more;
	countdown incoming = chain(12);
	check(zane_blocks() == 22);
	zane_overwrite((char *)a, (char *)&incoming, sizeof(countdown), &countdown_type);
	check(depth(a) == 12 && (countdown *)a->more == second && zane_blocks() == 12);
	zane_scope_drain(scope);
	check(zane_blocks() == 0);

	/* A countdown a hundred thousand boxes deep is copied, compared,
	   overwritten, moved and ended, its walks handed on past their depth,
	   with no depth limit. */
	scope = zane_scope_enter(0);
	countdown *deep = test_slot(scope, sizeof(countdown), 8, &countdown_type);
	*deep = chain(100000);
	countdown *twin = test_slot(scope, sizeof(countdown), 8, &countdown_type);
	*twin = *deep;
	zane_copy((char *)twin, &countdown_type);
	check(depth(twin) == 100000 && apart(deep, twin) && zane_blocks() == 200000);
	countdown *second_box = (countdown *)twin->more;
	countdown longer = chain(100001);
	zane_overwrite((char *)twin, (char *)&longer, sizeof(countdown), &countdown_type);
	check(depth(twin) == 100001 && (countdown *)twin->more == second_box && zane_blocks() == 200001);
	zane_mark *within = zane_scope_enter(0);
	countdown rising = chain(100000);
	zane_promote((char *)&rising, &countdown_type, within);
	zane_scope_drain(within);
	int out = 1;
	for (countdown *c = &rising; c->tag == 1; c = (countdown *)c->more)
		out &= zane_region_at(c->more) == scope;
	check(out && depth(&rising) == 100000 && zane_blocks() == 300001);
	zane_end((char *)&rising, &countdown_type);
	zane_end((char *)deep, &countdown_type);
	*deep = (countdown){ 0, NULL };
	check(depth(twin) == 100001 && zane_blocks() == 100001);
	zane_scope_drain(scope);
	check(zane_blocks() == 0);

	/* A work zeroed whole, rather than started, starts at its first push,
	   and gives its jobs back last first past the ones it keeps in itself. */
	zane_work zeroed = { 0 };
	for (int64_t i = 0; i < 10; i++) zane_work_push(&zeroed, (zane_job){ .extra = i });
	int64_t expected = 9, ordered = 1;
	zane_job job;
	while (zane_work_pop(&zeroed, &job)) ordered &= job.extra == expected--;
	zane_work_end(&zeroed);
	check(ordered && expected == -1);
}
