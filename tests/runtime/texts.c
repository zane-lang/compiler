/* The runtime's strings and the blocks they own, tested in C on their own
   (docs/design/lowering.md L17), over hand-written layouts. Each check prints `yes`
   when it holds and `no` when it does not. */

#include "zane_internal.h"

#include <math.h>
#include <float.h>
#include <locale.h>
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
	zane_text_f32(&formatted, 10.0f);
	check(holds(&formatted, "10"));
	zane_end((char *)&formatted, text_layout);
	zane_text_f64(&formatted, 10.0);
	check(holds(&formatted, "10"));
	zane_end((char *)&formatted, text_layout);
	zane_text_f64(&formatted, 0.0001);
	check(holds(&formatted, "1e-4"));
	zane_end((char *)&formatted, text_layout);
	zane_text_f32(&formatted, FLT_TRUE_MIN);
	check(holds(&formatted, "1e-45"));
	zane_end((char *)&formatted, text_layout);
	zane_text_f64(&formatted, DBL_TRUE_MIN);
	check(holds(&formatted, "5e-324"));
	zane_end((char *)&formatted, text_layout);

	/* Exercise a comma decimal separator where available. Formatting keeps
	   '.' and restores the host's locale; standard CI may have only C. */
	int locale_ok = 1;
	const char *locales[] = { "de_DE.UTF-8", "de_DE.utf8", "German_Germany.1252" };
	for (size_t i = 0; i < sizeof locales / sizeof *locales; i++) {
		if (!setlocale(LC_NUMERIC, locales[i])) continue;
		char decimal[16];
		snprintf(decimal, sizeof decimal, "%s", localeconv()->decimal_point);
		zane_text_f32(&formatted, 0.1f);
		locale_ok = locale_ok && holds(&formatted, "0.1");
		zane_end((char *)&formatted, text_layout);
		zane_text_f64(&formatted, 1.25);
		locale_ok = locale_ok && holds(&formatted, "1.25")
		            && strcmp(decimal, localeconv()->decimal_point) == 0;
		zane_end((char *)&formatted, text_layout);
		setlocale(LC_NUMERIC, "C");
		break;
	}

	check(locale_ok);
	check(zane_blocks() == 0);

	/* A join owns a block of its own; joining nothing owns none. */
	zane_text abcd;
	zane_text_join(&abcd, &ab, &cd);
	check(holds(&abcd, "abcd") && abcd.room == 4 && zane_blocks() == 1);
	zane_text none;
	zane_text_join(&none, &empty, &empty);
	check(none.length == 0 && none.room == 0 && zane_blocks() == 1);
	check(zane_text_equal(&abcd, &(zane_text){ "abcd", 4, 0 }) && !zane_text_equal(&ab, &cd));
	zane_end((char *)&abcd, text_layout);
	check(zane_blocks() == 0);

	/* A drain releases the blocks its scope's strings own with its region,
	   and leaves a literal's bytes alone. */
	int64_t scope = zane_scope_enter();
	zane_text *s = zane_slot(scope, sizeof(zane_text), 8, text_layout);
	zane_text_join(s, &ab, &cd);
	zane_text *literal = zane_slot(scope, sizeof(zane_text), 8, text_layout);
	*literal = ab;
	check(zane_blocks() == 1);
	zane_scope_drain(scope);
	check(zane_blocks() == 0 && holds(&ab, "ab"));

	/* A move takes the block along, and the spent slot returns nothing. */
	scope = zane_scope_enter();
	s = zane_slot(scope, sizeof(zane_text), 8, text_layout);
	zane_text_join(s, &ab, &ab);
	zane_text moving = *s;
	zane_vacate((char *)s, text_layout);
	zane_text *t = zane_slot(scope, sizeof(zane_text), 8, text_layout);
	*t = moving;
	zane_arrive((char *)t, text_layout);
	check(s->room == 0 && holds(t, "abab") && zane_blocks() == 1);

	/* An overwrite returns the block it replaces, and keeps the new one. */
	zane_text incoming;
	zane_text_join(&incoming, &cd, &cd);
	zane_overwrite((char *)t, (char *)&incoming, sizeof(zane_text), text_layout);
	check(holds(t, "cdcd") && zane_blocks() == 1);
	zane_scope_drain(scope);
	check(zane_blocks() == 0);

	/* A payload that disappears when the variant changes case dies with
	   its block: nothing references a payload (memory.md §2.8.1). */
	scope = zane_scope_enter();
	holder *h = zane_slot(scope, sizeof(holder), 8, holder_layout);
	h->tag = 0;
	zane_text_join(&h->held, &ab, &cd);
	holder emptied = { 1, { 0 } };
	zane_overwrite((char *)h, (char *)&emptied, sizeof(holder), holder_layout);
	check(h->tag == 1 && zane_blocks() == 0);
	holder full = { 0, { 0 } };
	zane_text_join(&full.held, &cd, &ab);
	zane_overwrite((char *)h, (char *)&full, sizeof(holder), holder_layout);
	check(holds(&h->held, "cdab") && zane_blocks() == 1);
	zane_scope_drain(scope);
	check(zane_blocks() == 0);

	/* A move into a deeper owner leaves the block where it is (memory.md
	   §3.5). The deeper scope's drain leaves it there too, dead, and it goes
	   with the region it is in. */
	int64_t outer = zane_scope_enter();
	zane_text *made = zane_slot(outer, sizeof(zane_text), 8, text_layout);
	zane_text_join(made, &ab, &cd);
	const char *bytes = made->bytes;
	zane_text moved = *made;
	zane_vacate((char *)made, text_layout);
	int64_t inner = zane_scope_enter();
	zane_text *deeper = zane_slot(inner, sizeof(zane_text), 8, text_layout);
	*deeper = moved;
	zane_arrive((char *)deeper, text_layout);
	check(deeper->bytes == bytes && zane_region_at(bytes) == zane_mark_at(zane_self, outer));
	zane_scope_drain(inner);
	check(zane_blocks() == 1);
	zane_scope_drain(outer);
	check(zane_blocks() == 0);

	/* A checked drain returns it from the deeper scope instead, and finds
	   no block still out in either region. */
	zane_checking = 1;
	outer = zane_scope_enter();
	made = zane_slot(outer, sizeof(zane_text), 8, text_layout);
	zane_text_join(made, &ab, &cd);
	moved = *made;
	zane_vacate((char *)made, text_layout);
	inner = zane_scope_enter();
	deeper = zane_slot(inner, sizeof(zane_text), 8, text_layout);
	*deeper = moved;
	zane_arrive((char *)deeper, text_layout);
	zane_scope_drain(inner);
	check(zane_blocks() == 0);
	zane_scope_drain(outer);
	zane_checking = 0;
}
