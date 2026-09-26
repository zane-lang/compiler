/* The runtime's lists and boxes, tested in C on their own (docs/lowering.md
   L17), over hand-written layouts. Each check prints `yes` when it holds and
   `no` when it does not. */

#include "../../runtime/zane.c"

#include <stddef.h>

static void check(int ok) { puts(ok ? "yes" : "no"); }

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
	for (int64_t i = 0; i < 100; i++)
		*(node *)zane_list_push(list, sizeof(node), node_layout) = (node){ 0, i };
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
	check(zane_blocks == 5);
	zane_scope_drain(scope);
	check(zane_blocks == 0);

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
	check(depth(a) == 2 && depth(b) == 2 && b->more != a->more && zane_blocks == 4);
	countdown done = { 0, NULL };
	zane_overwrite((char *)a, (char *)&done, sizeof(countdown), countdown_layout, 0);
	check(depth(a) == 0 && depth(b) == 2 && zane_blocks == 2);
	zane_scope_drain(scope);
	check(zane_blocks == 0);
}
