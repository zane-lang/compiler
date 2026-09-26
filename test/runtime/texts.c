/* The runtime's strings and the blocks they own, tested in C on their own
   (docs/lowering.md L17), over hand-written layouts. Each check prints `yes`
   when it holds and `no` when it does not. */

#include "../../runtime/zane.c"

#include <stddef.h>

static void check(int ok) { puts(ok ? "yes" : "no"); }

static int holds(const zane_text *t, const char *bytes) {
	return t->length == (int64_t)strlen(bytes) && memcmp(t->bytes, bytes, strlen(bytes)) == 0;
}

/* A host holding a string in a variant payload: `#variant { held String;
   empty Unit }`. */
typedef struct {
	uint32_t bp;
	int32_t tag;
	zane_text held;
} holder;

static const int64_t text_layout[] = {
	2,
	ZANE_HOST, 0, sizeof(zane_text), 0,
	ZANE_TEXT, 0, sizeof(zane_text), 0,
};
static const int64_t holder_layout[] = {
	3,
	ZANE_HOST, 0, sizeof(holder), 0,
	ZANE_HOST, offsetof(holder, held), sizeof(zane_text), 1, offsetof(holder, tag), 0,
	ZANE_TEXT, offsetof(holder, held), sizeof(zane_text), 1, offsetof(holder, tag), 0,
};

void zane_main(void) {
	zane_text ab = { 0, "ab", 2, 0 }, cd = { 0, "cd", 2, 0 }, empty = { 0, "", 0, 0 };

	/* A join owns a block of its own; joining nothing owns none. */
	zane_text abcd;
	zane_text_join(&abcd, &ab, &cd);
	check(holds(&abcd, "abcd") && abcd.room == 4 && zane_blocks == 1);
	zane_text none;
	zane_text_join(&none, &empty, &empty);
	check(none.length == 0 && none.room == 0 && zane_blocks == 1);
	check(zane_text_equal(&abcd, &(zane_text){ 0, "abcd", 4, 0 }) && !zane_text_equal(&ab, &cd));

	/* A drain returns the blocks its scope's strings own, and leaves a
	   literal's bytes alone. */
	int64_t scope = zane_scope_enter();
	zane_text *s = zane_slot(scope, sizeof(zane_text), 8, text_layout);
	*s = abcd;
	zane_text *literal = zane_slot(scope, sizeof(zane_text), 8, text_layout);
	*literal = ab;
	zane_scope_drain(scope);
	check(zane_blocks == 0);

	/* A move takes the block along, and the spent slot returns nothing. */
	scope = zane_scope_enter();
	s = zane_slot(scope, sizeof(zane_text), 8, text_layout);
	zane_text_join(s, &ab, &ab);
	zane_text moving = *s;
	zane_vacate((char *)s, text_layout);
	zane_text *t = zane_slot(scope, sizeof(zane_text), 8, text_layout);
	*t = moving;
	zane_arrive((char *)t, text_layout);
	check(s->room == 0 && holds(t, "abab") && zane_blocks == 1);

	/* An overwrite returns the block it replaces, and keeps the new one. */
	zane_text incoming;
	zane_text_join(&incoming, &cd, &cd);
	zane_overwrite((char *)t, (char *)&incoming, sizeof(zane_text), text_layout);
	check(holds(t, "cdcd") && zane_blocks == 1);
	zane_scope_drain(scope);
	check(zane_blocks == 0);

	/* A payload that floats takes its block along, and it stays readable
	   through the guest; one nobody names dies with its block. */
	scope = zane_scope_enter();
	holder *h = zane_slot(scope, sizeof(holder), 8, holder_layout);
	h->bp = 0;
	h->tag = 0;
	zane_text_join(&h->held, &ab, &cd);
	uint32_t g = zane_mint(&h->held);
	holder emptied = { 0, 1, { 0 } };
	zane_overwrite((char *)h, (char *)&emptied, sizeof(holder), holder_layout);
	check(holds(zane_resolve(g), "abcd") && zane_blocks == 0);
	h->tag = 0;
	zane_text_join(&h->held, &cd, &ab);
	zane_overwrite((char *)h, (char *)&emptied, sizeof(holder), holder_layout);
	check(zane_blocks == 0);
	zane_scope_drain(scope);
}
