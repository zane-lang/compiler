/* The runtime's strings and the blocks they own, tested in C on their own
   (docs/design/lowering.md L17), over hand-written layouts. Each check prints `yes`
   when it holds and `no` when it does not. */

#include "zane_internal.h"

#include <math.h>
#include <stddef.h>

static void check(int ok) { puts(ok ? "yes" : "no"); }

static int holds(const zane_text *t, const char *bytes) {
	return t->length == (int64_t)strlen(bytes) && memcmp(t->bytes, bytes, strlen(bytes)) == 0;
}

/* An owner holding a string in a variant payload: `#variant { held String;
   empty Unit }`. */
typedef struct {
	int32_t tag;
	zane_text held;
} holder;

static const int64_t text_layout[] = {
	1,
	ZANE_TEXT, 0, sizeof(zane_text), 0, 0, 0,
};
static const int64_t holder_layout[] = {
	1,
	ZANE_TEXT, offsetof(holder, held), sizeof(zane_text), 0, 0, 1, offsetof(holder, tag), 0,
};

void zane_main(void) {
	zane_text ab = { "ab", 2, 0 }, cd = { "cd", 2, 0 }, empty = { "", 0, 0 };

	/* Scalar constructors use decimal text that round-trips to the same
	   primitive, and every result owns exactly its bytes. */
	zane_text formatted;
	zane_text_i32(&formatted, INT32_MIN);
	check(holds(&formatted, "-2147483648") && formatted.room == formatted.length);
	zane_end((char *)&formatted, text_layout);
	zane_text_i64(&formatted, INT64_MIN);
	check(holds(&formatted, "-9223372036854775808"));
	zane_end((char *)&formatted, text_layout);
	zane_text_f32(&formatted, 0.1f);
	check(holds(&formatted, "0.1"));
	zane_end((char *)&formatted, text_layout);
	zane_text_f64(&formatted, 1.0 / 3.0);
	check(holds(&formatted, "0.3333333333333333"));
	zane_end((char *)&formatted, text_layout);
	zane_text_f32(&formatted, -0.0f);
	check(holds(&formatted, "-0"));
	zane_end((char *)&formatted, text_layout);
	zane_text_f64(&formatted, INFINITY);
	check(holds(&formatted, "inf"));
	zane_end((char *)&formatted, text_layout);
	zane_text_f64(&formatted, -INFINITY);
	check(holds(&formatted, "-inf"));
	zane_end((char *)&formatted, text_layout);
	zane_text_f64(&formatted, NAN);
	check(holds(&formatted, "nan"));
	zane_end((char *)&formatted, text_layout);
	check(zane_blocks == 0);

	/* A join owns a block of its own; joining nothing owns none. */
	zane_text abcd;
	zane_text_join(&abcd, &ab, &cd);
	check(holds(&abcd, "abcd") && abcd.room == 4 && zane_blocks == 1);
	zane_text none;
	zane_text_join(&none, &empty, &empty);
	check(none.length == 0 && none.room == 0 && zane_blocks == 1);
	check(zane_text_equal(&abcd, &(zane_text){ "abcd", 4, 0 }) && !zane_text_equal(&ab, &cd));

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

	/* A payload that disappears when the variant changes case dies with
	   its block: nothing references a payload (memory.md §2.8.1). */
	scope = zane_scope_enter();
	holder *h = zane_slot(scope, sizeof(holder), 8, holder_layout);
	h->tag = 0;
	zane_text_join(&h->held, &ab, &cd);
	holder emptied = { 1, { 0 } };
	zane_overwrite((char *)h, (char *)&emptied, sizeof(holder), holder_layout);
	check(h->tag == 1 && zane_blocks == 0);
	holder full = { 0, { 0 } };
	zane_text_join(&full.held, &cd, &ab);
	zane_overwrite((char *)h, (char *)&full, sizeof(holder), holder_layout);
	check(holds(&h->held, "cdab") && zane_blocks == 1);
	zane_scope_drain(scope);
	check(zane_blocks == 0);
}
