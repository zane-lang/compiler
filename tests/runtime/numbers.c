/* The runtime's reads of input, tested in C on their own (docs/design/lowering.md
   L17): numbers read from a string's text (types.md §2.10), held to the
   cases tests/unit/ holds the compile-time evaluator to, and the program's
   arguments as a list of strings (effects.md §6.6). Each check prints `yes`
   when it holds and `no` when it does not. */

#include "walks.h"

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

void zane_main(void) {
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

	/* The one-pass read, against the C library: decimals of 1 to 20 digits
	   with 0 to 23 after the point, on both sides of the quick path's
	   limits (19 digits, 2^53, 22 after the point), each the same double
	   strtod reads. */
	{
		uint64_t seed = 0x9E3779B97F4A7C15u;
		int same = 1;
		char buffer[64];
		for (int k = 0; k < 200000 && same; k++) {
			seed ^= seed << 13;
			seed ^= seed >> 7;
			seed ^= seed << 17;
			int digits = 1 + (int)(seed % 20), point = (int)((seed >> 8) % 24);
			if (point >= digits) point = digits - 1;
			int n = 0;
			if ((seed >> 16) & 1) buffer[n++] = '-';
			uint64_t r = seed;
			for (int d = 0; d < digits; d++) {
				if (point > 0 && d == digits - point) buffer[n++] = '.';
				r = r * 6364136223846793005u + 1442695040888963407u;
				buffer[n++] = (char)('0' + (r >> 60) % 10);
			}
			buffer[n] = '\0';
			same = f64_is(buffer, strtod(buffer, NULL));
		}
		check(same);
	}
	check(f64_is("9007199254740992", 9007199254740992.0) && f64_is("9007199254740993.0", 9007199254740992.0));
	check(f64_is("0.1", 0.1) && f64_is("123456789.0123456789", 123456789.0123456789));
	check(f64_is("1.0000000000000000000000", 1.0));
	check(f64_fails("-") && f64_fails("-.5") && f64_fails("1.2.3") && f64_fails("1-"));

	/* A range of a string's bytes, counted from 1, read as the whole of a
	   string; a range past the text is out of range. */
	{
		zane_text row = { "x,4.35,-0.125,", 14, 0 };
		double a = 0, b = 0, c = 5;
		check(zane_parse_f64_at(&row, &a, 3, 4) == 1 && a == 4.35);
		check(zane_parse_f64_at(&row, &b, 8, 6) == 1 && b == -0.125);
		check(zane_parse_f64_at(&row, &c, 1, 1) == 0 && zane_parse_f64_at(&row, &c, 3, 0) == 0 && c == 5);
	}

	/* The arguments, each a string owning a copy of its bytes in the
	   current scope's region, and an empty list when there are none. */
	int saved_count = zane_argc;
	char **saved = zane_argv;
	char *given[] = { "one", "", "three" };
	zane_argc = 3;
	zane_argv = given;
	zane_mark *scope = zane_scope_enter(0);
	zane_list *args = test_slot(scope, sizeof(zane_list), 8, &texts_type);
	zane_arguments(args);
	zane_text *items = (zane_text *)args->items;
	check(args->count == 3);
	check(items[0].length == 3 && memcmp(items[0].bytes, "one", 3) == 0 && items[0].bytes != given[0]);
	check(items[1].length == 0);
	check(items[2].length == 5 && memcmp(items[2].bytes, "three", 5) == 0);
	zane_arrive((char *)args, &texts_type);
	zane_scope_drain(scope);
	check(zane_blocks() == 0);

	zane_argc = 0;
	zane_list none;
	zane_arguments(&none);
	check(none.count == 0 && none.room == 0);
	zane_argc = saved_count;
	zane_argv = saved;
}
