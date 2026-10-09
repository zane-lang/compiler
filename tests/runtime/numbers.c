/* The runtime's reads of input, tested in C on their own (docs/design/lowering.md
   L17): numbers read from a string's text (types.md §2.10), held to the
   cases tests/unit/ holds the compile-time evaluator to, and the program's
   arguments as a list of strings (effects.md §6.6). Each check prints `yes`
   when it holds and `no` when it does not. */

#include "zane_internal.h"

#include <math.h>

static void check(int ok) { puts(ok ? "yes" : "no"); }

static int i64_is(const char *text, int64_t expected) {
	zane_text t = { text, (int64_t)strlen(text), 0 };
	int64_t value = 0;
	return zane_parse_i64(&t, &value) == 1 && value == expected;
}

static int i64_fails(const char *text) {
	zane_text t = { text, (int64_t)strlen(text), 0 };
	int64_t value = 5;
	return zane_parse_i64(&t, &value) == 0 && value == 5;
}

static int f64_is(const char *text, double expected) {
	zane_text t = { text, (int64_t)strlen(text), 0 };
	double value = 0;
	return zane_parse_f64(&t, &value) == 1 && memcmp(&value, &expected, sizeof value) == 0;
}

static int f64_fails(const char *text) {
	zane_text t = { text, (int64_t)strlen(text), 0 };
	double value = 5;
	return zane_parse_f64(&t, &value) == 0 && value == 5;
}

static const int64_t text_layout[] = {
	1,
	ZANE_TEXT, 0, sizeof(zane_text), 0, 0, 0,
};
static int64_t texts_layout[] = {
	1,
	ZANE_LIST, 0, sizeof(zane_list), sizeof(zane_text), 0, 0,
};

void zane_main(void) {
	texts_layout[1 + 4] = (int64_t)(intptr_t)text_layout;

	check(i64_is("42", 42));
	check(i64_is("-7", -7));
	check(i64_is("007", 7));
	check(i64_is("9223372036854775807", INT64_MAX));
	check(i64_is("-9223372036854775808", INT64_MIN));
	check(i64_fails("9223372036854775808"));
	check(i64_fails(""));
	check(i64_fails("-"));
	check(i64_fails("+5"));
	check(i64_fails(" 5") && i64_fails("5 "));
	check(i64_fails("1_000"));
	check(i64_fails("0x10"));
	check(i64_fails("3.25"));

	check(f64_is("3.25", 3.25));
	check(f64_is("-7", -7.0));
	check(f64_is("-0.0", -0.0));
	check(f64_is("9007199254740993", 9007199254740992.0));
	check(f64_fails("3.") && f64_fails(".5"));
	check(f64_fails("1e5"));
	check(f64_fails("nan") && f64_fails("inf"));
	char huge[402];
	huge[0] = '1';
	memset(huge + 1, '0', 400);
	huge[401] = '\0';
	check(f64_fails(huge));

	/* The arguments, each a string owning a copy of its bytes in the
	   current scope's region, and an empty list when there are none. */
	int saved_count = zane_argc;
	char **saved = zane_argv;
	char *given[] = { "one", "", "three" };
	zane_argc = 3;
	zane_argv = given;
	int64_t scope = zane_scope_enter();
	zane_list *args = zane_slot(scope, sizeof(zane_list), 8, texts_layout);
	zane_arguments(args);
	zane_text *items = (zane_text *)args->items;
	check(args->count == 3);
	check(items[0].length == 3 && memcmp(items[0].bytes, "one", 3) == 0 && items[0].bytes != given[0]);
	check(items[1].length == 0);
	check(items[2].length == 5 && memcmp(items[2].bytes, "three", 5) == 0);
	zane_arrive((char *)args, texts_layout);
	zane_scope_drain(scope);
	check(zane_blocks() == 0);

	zane_argc = 0;
	zane_list none;
	zane_arguments(&none);
	check(none.count == 0 && none.room == 0);
	zane_argc = saved_count;
	zane_argv = saved;
}
