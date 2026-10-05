/* The runtime's lists, arrays, boxes, dynamic regions and package
   constants, tested in C on their own (docs/design/lowering.md L17), over
   hand-written layouts. Each check prints `yes` when it holds and `no` when
   it does not. */

#include "zane_internal.h"

#include <stddef.h>

static void check(int ok) { puts(ok ? "yes" : "no"); }

/* The scope whose region holds `at`. */
static int64_t zane_region_of(const void *at) { return zane_region_at(at)->depth; }

/* An owner of one `Int`, a list of them, a list of strings, and a value
   that boxes itself: `variant { done Unit; more Countdown; }`. */
typedef struct {
	int64_t value;
} node;

typedef struct {
	int32_t tag;
	char *more;
} countdown;

/* A struct that boxes a node: `#struct { id Int; inner Box; }`, where the
   box holds `#struct { value Int; name String; }`. */
typedef struct {
	int64_t value;
	zane_text name;
} named;

typedef struct {
	int64_t id;
	char *inner;
} outer_t;

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
static const int64_t named_layout[] = {
	1,
	ZANE_TEXT, offsetof(named, name), sizeof(zane_text), 0, 0, 0,
};
static int64_t outer_layout[] = {
	1,
	ZANE_BOX, offsetof(outer_t, inner), sizeof(char *), sizeof(named), 0, 0,
};

static int depth(const countdown *c) { return c->tag == 1 ? 1 + depth((countdown *)c->more) : 0; }

void zane_main(void) {
	/* A position's fifth word is the layout of what its block holds, an
	   address known only at run time. */
	texts_layout[1 + 4] = (int64_t)(intptr_t)text_layout;
	countdown_layout[1 + 4] = (int64_t)(intptr_t)countdown_layout;
	outer_layout[1 + 4] = (int64_t)(intptr_t)named_layout;
	int64_t scope = zane_scope_enter();

	/* An element's bytes move with every block the list grows into, and
	   the list owns one block at a time. */
	zane_list *list = zane_slot(scope, sizeof(zane_list), 8, NULL);
	zane_list_new(list);
	node *first = zane_list_push(list, sizeof(node));
	*first = (node){ 7 };
	/* A block after the list's keeps it from growing where it is. */
	void *after = zane_box(8, 8);
	for (int64_t i = 0; i < 100; i++) *(node *)zane_list_push(list, sizeof(node)) = (node){ i };
	zane_free(after, 8, 8);
	node *now = zane_list_at(list, 1, sizeof(node));
	check(now->value == 7 && now != first);
	check(list->count == 101 && list->room == 1024 && zane_blocks == 1);
	zane_free(list->items, list->room, ZANE_LINE);
	*list = (zane_list){ NULL, 0, 0 };

	/* A list of strings returns every block it owns at the drain. */
	zane_list *words = zane_slot(scope, sizeof(zane_list), 8, texts_layout);
	zane_list_new(words);
	zane_text ab = { "ab", 2, 0 };
	for (int i = 0; i < 3; i++) zane_text_join(zane_list_push(words, sizeof(zane_text)), &ab, &ab);
	check(zane_blocks == 4);
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
	zane_overwrite((char *)a, (char *)&done, sizeof(countdown), countdown_layout);
	check(depth(a) == 0 && depth(b) == 2 && zane_blocks == 2);
	zane_scope_drain(scope);
	check(zane_blocks == 0);

	/* An overwrite is in place (memory.md §2.2): a boxed member keeps its
	   block, so an address into it still names the member, which now holds
	   the replacement; the replacement's own block and the bytes the old
	   member owned are returned. */
	scope = zane_scope_enter();
	outer_t *o = zane_slot(scope, sizeof(outer_t), 8, outer_layout);
	named *kept_box = zane_box(sizeof(named), 8);
	*kept_box = (named){ 1, { NULL, 0, 0 } };
	zane_text_join(&kept_box->name, &ab, &ab);
	*o = (outer_t){ 10, (char *)kept_box };
	named *seen = (named *)o->inner;
	outer_t incoming = { 20, zane_box(sizeof(named), 8) };
	*(named *)incoming.inner = (named){ 2, { NULL, 0, 0 } };
	zane_text_join(&((named *)incoming.inner)->name, &ab, &(zane_text){ "cd", 2, 0 });
	check(zane_blocks == 4);
	zane_overwrite((char *)o, (char *)&incoming, sizeof(outer_t), outer_layout);
	check(o->id == 20 && o->inner == (char *)kept_box && seen->value == 2 &&
	      memcmp(seen->name.bytes, "abcd", 4) == 0 && zane_blocks == 2);
	zane_scope_drain(scope);
	check(zane_blocks == 0);

	/* Arriving in an inner scope leaves blocks in an enclosing one where
	   they are, since that one outlives the destination; arriving in an
	   enclosing scope moves them out first, which is an escape (§3.5). */
	int64_t enclosing = zane_scope_enter();
	zane_text made;
	zane_text_join(&made, &ab, &ab);
	int64_t nested = zane_scope_enter();
	zane_text *down = zane_slot(nested, sizeof(zane_text), 8, text_layout);
	*down = made;
	zane_arrive((char *)down, text_layout);
	check(zane_region_of(down->bytes) == enclosing);
	zane_text young;
	zane_text_join(&young, &ab, &ab);
	zane_promote((char *)&young, text_layout, nested);
	zane_vacate((char *)down, text_layout);
	zane_scope_drain(nested);
	check(zane_region_of(young.bytes) == enclosing);
	zane_text *up = zane_slot(enclosing, sizeof(zane_text), 8, text_layout);
	*up = young;
	zane_text *other_up = zane_slot(enclosing, sizeof(zane_text), 8, text_layout);
	*other_up = made;
	zane_scope_drain(enclosing);
	check(zane_blocks == 0);

	/* A list's block grows where it is while it is the last thing at its
	   region's frontier, and a block it gives back serves the next of its
	   size. */
	int64_t outer = zane_scope_enter();
	zane_list *ints = zane_slot(outer, sizeof(zane_list), 8, NULL);
	zane_list_new(ints);
	for (int64_t i = 0; i < 16; i++) *(int64_t *)zane_list_push(ints, 8) = i;
	char *before = ints->items;
	*(int64_t *)zane_list_push(ints, 8) = 16;
	check(ints->items == before && ints->room == 256 && zane_blocks == 1);
	zane_list *other = zane_slot(outer, sizeof(zane_list), 8, NULL);
	zane_list_new(other);
	zane_list_push(other, 8);
	char *first_block = other->items;
	after = zane_box(8, 8);
	for (int64_t i = 0; i < 16; i++) zane_list_push(other, 8);
	zane_free(after, 8, 8);
	zane_list *third = zane_slot(outer, sizeof(zane_list), 8, NULL);
	zane_list_new(third);
	zane_list_push(third, 8);
	check(other->items != first_block && third->items == first_block);

	/* A list pushed to from an inner scope keeps its block in the scope
	   that holds it, and a string leaving an inner scope moves its bytes
	   out before the drain. */
	int64_t inner_scope = zane_scope_enter();
	for (int64_t i = 0; i < 100; i++) zane_list_push(third, 8);
	zane_text left;
	zane_text_join(&left, &(zane_text){ "ab", 2, 0 }, &(zane_text){ "cd", 2, 0 });
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
		zane_list emptied = { NULL, 0, 0 };
		zane_list *l = lists[i];
		/* These lists were placed with no layout, so return their blocks
		   by hand. */
		zane_free(l->items, l->room, ZANE_LINE);
		*l = emptied;
	}
	zane_scope_drain(outer);
	check(zane_blocks == 0);

	/* A layout that lists nothing may be no table at all. */
	int64_t plain = 1, replacing_plain = 2;
	zane_arrive((char *)&plain, NULL);
	zane_promote((char *)&plain, NULL, 1);
	zane_copy((char *)&plain, NULL);
	zane_overwrite((char *)&plain, (char *)&replacing_plain, 8, NULL);
	zane_vacate((char *)&plain, NULL);
	check(plain == 2);

	/* An array's element, counted from 1, is its stride apart from the one
	   before it. */
	int64_t numbers[3] = { 7, 8, 9 };
	check(*(int64_t *)zane_array_at((char *)numbers, 1, 3, 8) == 7 &&
	      *(int64_t *)zane_array_at((char *)numbers, 3, 3, 8) == 9);

	/* A package constant is made once, by the first reader, and the block
	   it owns moves into the program's own region, where it outlives the
	   scope it was made in. */
	static int64_t state;
	static zane_text constant;
	int64_t making = zane_scope_enter();
	check(zane_constant_begin(&state) == 1);
	zane_text_join(&constant, &(zane_text){ "ab", 2, 0 }, &(zane_text){ "cd", 2, 0 });
	zane_constant_end(&state, (char *)&constant, text_layout);
	zane_scope_drain(making);
	check(zane_region_at(constant.bytes) == zane_program && memcmp(constant.bytes, "abcd", 4) == 0);
	check(zane_constant_begin(&state) == 0);
}
