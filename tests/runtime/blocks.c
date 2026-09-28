/* The runtime's lists, boxes and dynamic regions, tested in C on their own
   (docs/design/lowering.md L17), over hand-written layouts. Each check prints `yes`
   when it holds and `no` when it does not. */

#include "zane_internal.h"

#include <stddef.h>

static void check(int ok) { puts(ok ? "yes" : "no"); }

/* The scope whose region holds `at`. */
static int64_t zane_region_of(const void *at) { return zane_region_at(at)->depth; }

/* A host of one `Int`, a list of them, a list of strings, and a value that
   boxes itself: `variant { done Unit; more Countdown; }`. */
typedef struct {
	uint32_t bp;
	int64_t value;
} node;

typedef struct {
	int32_t tag;
	char *more;
} countdown;

static const int64_t node_layout[] = { 1, ZANE_HOST, 0, sizeof(node), 0, 0, 0 };
static const int64_t text_layout[] = {
	2,
	ZANE_HOST, 0, sizeof(zane_text), 0, 0, 0,
	ZANE_TEXT, 0, sizeof(zane_text), 0, 0, 0,
};
static int64_t nodes_layout[] = {
	2,
	ZANE_HOST, 0, sizeof(zane_list), 0, 0, 0,
	ZANE_LIST, 0, sizeof(zane_list), sizeof(node), 0, 0,
};
static int64_t texts_layout[] = {
	2,
	ZANE_HOST, 0, sizeof(zane_list), 0, 0, 0,
	ZANE_LIST, 0, sizeof(zane_list), sizeof(zane_text), 0, 0,
};
static int64_t countdown_layout[] = {
	1,
	ZANE_BOX, offsetof(countdown, more), sizeof(char *), sizeof(countdown), 0, 1,
	offsetof(countdown, tag), 1,
};

static int depth(const countdown *c) { return c->tag == 1 ? 1 + depth((countdown *)c->more) : 0; }

void zane_main(void) {
	/* A position's fifth word is the layout of what its block holds, an
	   address known only at run time. */
	nodes_layout[1 + 6 + 4] = (int64_t)(intptr_t)node_layout;
	texts_layout[1 + 6 + 4] = (int64_t)(intptr_t)text_layout;
	countdown_layout[1 + 4] = (int64_t)(intptr_t)countdown_layout;
	int64_t scope = zane_scope_enter();

	/* An element's guest follows it through every block the list grows
	   into, and the list owns one block at a time. */
	zane_list *list = zane_slot(scope, sizeof(zane_list), 8, nodes_layout);
	zane_list_new(list);
	node *first = zane_list_push(list, sizeof(node), node_layout);
	*first = (node){ 0, 7 };
	uint32_t g = zane_mint(first);
	/* A block after the list's keeps it from growing where it is. */
	void *after = zane_box(8, 8);
	for (int64_t i = 0; i < 100; i++)
		*(node *)zane_list_push(list, sizeof(node), node_layout) = (node){ 0, i };
	zane_free(after, 8, 8);
	node *now = zane_resolve(g);
	check(now == zane_list_at(list, 1, sizeof(node)) && now->value == 7 && now != first);
	check(list->count == 101 && list->room == 2048 && zane_blocks == 1);

	/* An anchored element replaced at its index floats, keeping its value
	   for its guest, and the element takes the new one. */
	node replacing = { 0, 9 };
	zane_overwrite((char *)now, (char *)&replacing, sizeof(node), node_layout, 1);
	check(((node *)zane_resolve(g))->value == 7 && now->value == 9 && now->bp == 0);

	/* A list of strings returns every block it owns at the drain. */
	zane_list *words = zane_slot(scope, sizeof(zane_list), 8, texts_layout);
	zane_list_new(words);
	zane_text ab = { 0, "ab", 2, 0 };
	for (int i = 0; i < 3; i++)
		zane_text_join(zane_list_push(words, sizeof(zane_text), NULL), &ab, &ab);
	check(zane_blocks - zane_floated == 5);
	zane_scope_drain(scope);
	check(zane_blocks - zane_floated == 0);

	/* A copy of a boxed value owns blocks of its own, and each is returned
	   once. */
	scope = zane_scope_enter();
	countdown *a = zane_slot(scope, sizeof(countdown), 8, countdown_layout);
	countdown *inner = zane_box(sizeof(countdown), 8);
	*inner = (countdown){ 0, NULL };
	*a = (countdown){ 1, zane_box(sizeof(countdown), 8) };
	*(countdown *)a->more = (countdown){ 1, (char *)inner };
	countdown *b = zane_slot(scope, sizeof(countdown), 8, countdown_layout);
	*b = *a;
	zane_copy((char *)b, countdown_layout);
	check(depth(a) == 2 && depth(b) == 2 && b->more != a->more && zane_blocks - zane_floated == 4);
	countdown done = { 0, NULL };
	zane_overwrite((char *)a, (char *)&done, sizeof(countdown), countdown_layout, 0);
	check(depth(a) == 0 && depth(b) == 2 && zane_blocks - zane_floated == 2);
	zane_scope_drain(scope);
	check(zane_blocks - zane_floated == 0);

	/* A list's block grows where it is while it is the last thing at its
	   region's frontier, and a block it gives back serves the next of its
	   size. */
	int64_t outer = zane_scope_enter();
	zane_list *ints = zane_slot(outer, sizeof(zane_list), 8, NULL);
	zane_list_new(ints);
	for (int64_t i = 0; i < 16; i++) *(int64_t *)zane_list_push(ints, 8, NULL) = i;
	char *before = ints->items;
	*(int64_t *)zane_list_push(ints, 8, NULL) = 16;
	check(ints->items == before && ints->room == 256 && zane_blocks - zane_floated == 1);
	zane_list *other = zane_slot(outer, sizeof(zane_list), 8, NULL);
	zane_list_new(other);
	zane_list_push(other, 8, NULL);
	char *first_block = other->items;
	after = zane_box(8, 8);
	for (int64_t i = 0; i < 16; i++) zane_list_push(other, 8, NULL);
	zane_free(after, 8, 8);
	zane_list *third = zane_slot(outer, sizeof(zane_list), 8, NULL);
	zane_list_new(third);
	zane_list_push(third, 8, NULL);
	check(other->items != first_block && third->items == first_block);

	/* A list pushed to from an inner scope keeps its block in the scope
	   that holds it, and a string leaving an inner scope moves its bytes
	   out before the drain. */
	int64_t inner_scope = zane_scope_enter();
	for (int64_t i = 0; i < 100; i++) zane_list_push(third, 8, NULL);
	zane_text left;
	zane_text_join(&left, &(zane_text){ 0, "ab", 2, 0 }, &(zane_text){ 0, "cd", 2, 0 });
	check(zane_region_of(left.bytes) == inner_scope);
	zane_promote((char *)&left, text_layout, inner_scope);
	zane_scope_drain(inner_scope);
	check(zane_region_of(third->items) == outer && zane_region_of(left.bytes) == outer &&
	      memcmp(left.bytes, "abcd", 4) == 0);
	zane_text *kept = zane_slot(outer, sizeof(zane_text), 8, text_layout);
	*kept = left;
	zane_arrive((char *)kept, text_layout);
	zane_list *lists[] = { ints, other, third };
	for (int i = 0; i < 3; i++) {
		zane_list emptied = { 0, NULL, 0, 0 };
		zane_list *l = lists[i];
		/* These lists were placed with no layout, so return their blocks
		   by hand. */
		zane_free(l->items, l->room, ZANE_LINE);
		*l = emptied;
	}
	zane_scope_drain(outer);
	check(zane_blocks - zane_floated == 0);

	/* A layout that lists nothing may be no table at all. */
	int64_t plain = 1, replacing_plain = 2;
	zane_arrive((char *)&plain, NULL);
	zane_promote((char *)&plain, NULL, 1);
	zane_copy((char *)&plain, NULL);
	zane_overwrite((char *)&plain, (char *)&replacing_plain, 8, NULL, 0);
	zane_vacate((char *)&plain, NULL);
	check(plain == 2);
}
