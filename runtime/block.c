#include "zane_internal.h"

#include <errno.h>
#include <inttypes.h>
#include <locale.h>
#include <math.h>

/* ---------------------------------------------------------------------- */
/* Dynamic blocks (memory.md §3.6, docs/design/lowering.md §9)                   */
/* ---------------------------------------------------------------------- */

/* Where a layout's positions are: a count, then for each position its kind,
   offset, size, a list's stride or a box's payload size, the layout of a
   list's elements or a box's payload, and the variant tags that must be live
   for it to be there, as a count and then (tag offset, tag) pairs. */
int zane_next_position(const int64_t *layout, int64_t *cursor, int64_t *left,
                       zane_position *p) {
	if (*left == 0) return 0;
	const int64_t *at = layout + *cursor;
	*p = (zane_position){ at[0], at[1], at[2], at[3], (const int64_t *)(intptr_t)at[4], at[5],
		                  at + 6 };
	*cursor += 6 + 2 * at[5];
	(*left)--;
	return 1;
}

/* Whether a position is there: every variant tag it lies under is live. */
int zane_present(const char *base, const zane_position *p) {
	for (int64_t i = 0; i < p->conditions; i++)
		if (*(const int32_t *)(base + p->tags[2 * i]) != (int32_t)p->tags[2 * i + 1]) return 0;
	return 1;
}

/* A block is returned when the handle or boxed member that owns it dies,
   to the region it is in. What it is decides its size and alignment: a
   string's bytes are as long as its room, a list's elements start at a
   cache line (memory.md §3.6), and a box holds one payload. */
void zane_unblock(const zane_position *p, void *block, int64_t room) {
	zane_free(block, p->kind == ZANE_BOX ? p->extra : room, p->kind == ZANE_LIST ? ZANE_LINE : 8);
}

void *zane_at(char *base, const zane_position *p) { return base + p->offset; }

void zane_work_push(zane_work *w, zane_job job) {
	if (w->count == w->room) {
		w->room = w->room ? 2 * w->room : 64;
		w->jobs = realloc(w->jobs, (size_t)w->room * sizeof *w->jobs);
		if (!w->jobs) zane_broken("out of memory for a value's blocks");
	}
	w->jobs[w->count++] = job;
}

int zane_work_pop(zane_work *w, zane_job *job) {
	if (w->count == 0) return 0;
	*job = w->jobs[--w->count];
	return 1;
}

void zane_work_end(zane_work *w) {
	free(w->jobs);
	*w = (zane_work){ 0 };
}

/* One position of a dying value: a string's block is returned at once; a
   list's elements and a box's payload die first, so their block is
   returned by a job pushed beneath theirs, after them. */
static void zane_end_position(zane_work *w, char *base, const zane_position *p) {
	switch (p->kind) {
	case ZANE_TEXT: {
		zane_text *t = zane_at(base, p);
		if (t->room) zane_unblock(p, (void *)t->bytes, t->room);
		t->bytes = NULL;
		t->length = t->room = 0;
		break;
	}
	case ZANE_LIST: {
		zane_list *l = zane_at(base, p);
		if (l->room)
			zane_work_push(w, (zane_job){ .block = *p, .returned = l->items, .size = l->room });
		if (p->inner && p->inner[0] > 0)
			for (int64_t i = 0; i < l->count; i++)
				zane_work_push(w, (zane_job){ .at = l->items + i * p->extra, .layout = p->inner });
		l->items = NULL;
		l->count = l->room = 0;
		break;
	}
	case ZANE_BOX: {
		char **box = zane_at(base, p);
		if (!*box) break;
		zane_work_push(w, (zane_job){ .block = *p, .returned = *box });
		if (p->inner && p->inner[0] > 0)
			zane_work_push(w, (zane_job){ .at = *box, .layout = p->inner });
		*box = NULL;
		break;
	}
	}
}

static void zane_end_all(zane_work *w) {
	zane_job job;
	while (zane_work_pop(w, &job)) {
		if (job.block.kind) {
			zane_unblock(&job.block, job.returned, job.size);
			continue;
		}
		zane_position p;
		ZANE_EACH(job.layout, p) {
			if (zane_present(job.at, &p)) zane_end_position(w, job.at, &p);
		}
	}
	zane_work_end(w);
}

/* The block the handle or boxed member at `p` owns is returned, once what
   lives in it has died. */
void zane_end_at(char *base, const zane_position *p) {
	zane_work w = { 0 };
	zane_end_position(&w, base, p);
	zane_end_all(&w);
}

/* The value at `base` dies: each block it owns is returned, down through
   the blocks inside them (lifetimes.md §2.1). */
void zane_end(char *base, const int64_t *layout) {
	zane_work w = { 0 };
	zane_work_push(&w, (zane_job){ .at = base, .layout = layout });
	zane_end_all(&w);
}

/* The scope a value is made in is the innermost; where it arrives decides
   where its blocks end up. */
static zane_mark *zane_here(void) { return zane_mark_at(zane_self, zane_self->depth - 1); }

/* The value at `value` was copied from another place: each block it names
   is still the original's, so it gets a copy of its own, down through the
   blocks inside it (memory.md §2.3). */
void zane_copy(char *value, const int64_t *layout) {
	zane_work w = { 0 };
	zane_work_push(&w, (zane_job){ .at = value, .layout = layout });
	zane_job job;
	while (zane_work_pop(&w, &job)) {
		zane_position p;
		ZANE_EACH(job.layout, p) {
			if (!zane_present(job.at, &p)) continue;
			switch (p.kind) {
			case ZANE_TEXT: {
				zane_text *t = zane_at(job.at, &p);
				if (!t->room) break;
				char *bytes = zane_alloc(zane_here(), t->length, 8);
				memcpy(bytes, t->bytes, (size_t)t->length);
				t->bytes = bytes;
				t->room = t->length;
				break;
			}
			case ZANE_LIST: {
				zane_list *l = zane_at(job.at, &p);
				if (!l->room) break;
				char *items = zane_alloc(zane_here(), l->room, ZANE_LINE);
				memcpy(items, l->items, (size_t)(l->count * p.extra));
				l->items = items;
				if (p.inner && p.inner[0] > 0)
					for (int64_t i = 0; i < l->count; i++)
						zane_work_push(&w, (zane_job){ .at = items + i * p.extra, .layout = p.inner });
				break;
			}
			case ZANE_BOX: {
				char **box = zane_at(job.at, &p);
				if (!*box) break;
				char *payload = zane_alloc(zane_here(), p.extra, 8);
				memcpy(payload, *box, (size_t)p.extra);
				*box = payload;
				if (p.inner && p.inner[0] > 0)
					zane_work_push(&w, (zane_job){ .at = payload, .layout = p.inner });
				break;
			}
			}
		}
	}
	zane_work_end(&w);
}

/* A boxed member's block (memory.md §3.6): exactly one payload's size. */
void *zane_box(int64_t size, int64_t align) { return zane_alloc(zane_here(), size, align); }

/* A scalar's String constructor. Floats use compact decimal text that
   parses back to the same scalar; special floats have fixed spellings. */
static void zane_text_from_buffer(zane_text *out, const char *buffer, int length) {
	if (length <= 0) {
		*out = (zane_text){ "", 0, 0 };
		return;
	}
	char *bytes = zane_alloc(zane_here(), length, 8);
	memcpy(bytes, buffer, (size_t)length);
	*out = (zane_text){ bytes, length, length };
}

static int zane_same_f32(float left, float right) {
	uint32_t l, r;
	memcpy(&l, &left, sizeof l);
	memcpy(&r, &right, sizeof r);
	return l == r;
}

static int zane_same_f64(double left, double right) {
	uint64_t l, r;
	memcpy(&l, &left, sizeof l);
	memcpy(&r, &right, sizeof r);
	return l == r;
}

/* One immutable C numeric locale, shared by all runtime threads. Formatting
   must not change the host's process locale. POSIX selects it only on this
   thread; Windows CRT calls take it explicitly. */
static pthread_once_t zane_numeric_once = PTHREAD_ONCE_INIT;
#ifdef _WIN32
static _locale_t zane_numeric_locale;
#else
static locale_t zane_numeric_locale;
#endif

static void zane_numeric_init(void) {
#ifdef _WIN32
	zane_numeric_locale = _create_locale(LC_NUMERIC, "C");
#else
	zane_numeric_locale = newlocale(LC_NUMERIC_MASK, "C", (locale_t)0);
#endif
	if (!zane_numeric_locale) zane_broken("creating the numeric locale");
}

/* Canonical scientific notation: no redundant mantissa zeroes, exponent
   plus sign or exponent padding (which differs between C libraries). */
static int zane_decimal_text(char *buffer) {
	char *exponent = strchr(buffer, 'e');
	if (exponent) {
		int power = (int)strtol(exponent + 1, NULL, 10);
		char *end = exponent;
		if (strchr(buffer, '.')) {
			while (end[-1] == '0') end--;
			if (end[-1] == '.') end--;
		}
		/* The normalized exponent cannot be longer than the original. */
		sprintf(end, "e%d", power);
	}
	return (int)strlen(buffer);
}

static int zane_format_float(char *buffer, size_t room, double value, int single) {
	if (isnan(value)) return snprintf(buffer, room, "nan");
	if (isinf(value)) return snprintf(buffer, room, signbit(value) ? "-inf" : "inf");
	if (pthread_once(&zane_numeric_once, zane_numeric_init))
		zane_broken("initializing the numeric locale");
#ifndef _WIN32
	locale_t previous = uselocale(zane_numeric_locale);
	if (!previous) zane_broken("selecting the numeric locale");
#endif
	int best = 0;
	int limit = single ? 9 : 17;
	for (int precision = 1; precision <= limit; precision++) {
		/* %g can prefer fixed notation even when scientific text is shorter
		   (0.0001), or scientific when fixed is shorter (10). Try both. */
		for (int scientific = 0; scientific <= 1; scientific++) {
			char candidate[64];
			const char *format = scientific ? "%.*e" : "%.*g";
#ifdef _WIN32
			int length = _snprintf_l(candidate, sizeof candidate, format, zane_numeric_locale,
			                         precision - scientific, value);
#else
			int length = snprintf(candidate, sizeof candidate, format, precision - scientific, value);
#endif
			if (length < 0 || (size_t)length >= sizeof candidate)
				zane_broken("formatting a float");
			length = zane_decimal_text(candidate);
			char *end;
#ifdef _WIN32
			/* MinGW's MSVCRT lacks _strtof_l; rounding a parsed double
			   also matches the compile-time evaluator's F32 check. */
			int same = single
			    ? zane_same_f32((float)value, (float)_strtod_l(candidate, &end, zane_numeric_locale))
			    : zane_same_f64(value, _strtod_l(candidate, &end, zane_numeric_locale));
#else
			int same = single ? zane_same_f32((float)value, strtof(candidate, &end))
			                  : zane_same_f64(value, strtod(candidate, &end));
#endif
			if (*end == '\0' && same && (!best || length < best)) {
				if ((size_t)length >= room) zane_broken("formatting a float");
				memcpy(buffer, candidate, (size_t)length + 1);
				best = length;
			}
		}
	}
#ifndef _WIN32
	if (!uselocale(previous)) zane_broken("restoring the numeric locale");
#endif
	if (!best) zane_broken("formatting a float");
	return best;
}

void zane_text_i32(zane_text *out, int32_t value) {
	char buffer[32];
	int length = snprintf(buffer, sizeof buffer, "%" PRId32, value);
	if (length < 0 || (size_t)length >= sizeof buffer) zane_broken("formatting an I32");
	zane_text_from_buffer(out, buffer, length);
}

void zane_text_i64(zane_text *out, int64_t value) {
	char buffer[32];
	int length = snprintf(buffer, sizeof buffer, "%" PRId64, value);
	if (length < 0 || (size_t)length >= sizeof buffer) zane_broken("formatting an I64");
	zane_text_from_buffer(out, buffer, length);
}

void zane_text_f32(zane_text *out, float value) {
	char buffer[64];
	zane_text_from_buffer(out, buffer, zane_format_float(buffer, sizeof buffer, value, 1));
}

void zane_text_f64(zane_text *out, double value) {
	char buffer[64];
	zane_text_from_buffer(out, buffer, zane_format_float(buffer, sizeof buffer, value, 0));
}

/* `@runtime$Console`'s `print` (effects.md §6.6): exactly the string's
   length in bytes, with no terminator and nothing added. */
void zane_print(const zane_text *text) {
	fwrite(text->bytes, 1, (size_t)text->length, stdout);
}

/* `+` on `@primitives$String`: a new string that owns its bytes. */
void zane_text_join(zane_text *out, const zane_text *left, const zane_text *right) {
	int64_t length = left->length + right->length;
	if (length == 0) {
		*out = (zane_text){ "", 0, 0 };
		return;
	}
	char *bytes = zane_alloc(zane_here(), length, 8);
	/* A side with no bytes may have no block either, and memcpy is not
	   given a null pointer even for zero bytes. */
	if (left->length) memcpy(bytes, left->bytes, (size_t)left->length);
	if (right->length) memcpy(bytes + left->length, right->bytes, (size_t)right->length);
	*out = (zane_text){ bytes, length, length };
}

/* `==` on `@primitives$String`: the same bytes. */
int64_t zane_text_equal(const zane_text *left, const zane_text *right) {
	return left->length == right->length &&
	       (left->length == 0 || memcmp(left->bytes, right->bytes, (size_t)left->length) == 0);
}

/* Whether a string spells a number as `parseI64` and `parseF64` read one
   (types.md §2.10): a literal's digits with an optional `-` first and, when
   `fraction` is set, an optional `.` with digits on both sides. */
static int zane_numeric_text(const zane_text *text, int fraction) {
	int64_t n = text->length, i = 0;
	const char *b = text->bytes;
	if (n > 0 && b[0] == '-') i++;
	int64_t start = i;
	while (i < n && b[i] >= '0' && b[i] <= '9') i++;
	if (i == start) return 0;
	if (i == n) return 1;
	if (!fraction || b[i] != '.') return 0;
	int64_t point = ++i;
	while (i < n && b[i] >= '0' && b[i] <= '9') i++;
	return i > point && i == n;
}

/* The text with a terminator, for the C library to read. */
static char *zane_terminated(const zane_text *text) {
	char *s = malloc((size_t)text->length + 1);
	if (!s) zane_broken("out of memory for a number's text");
	memcpy(s, text->bytes, (size_t)text->length);
	s[text->length] = '\0';
	return s;
}

/* `parseI64` on `@primitives$String`: 1 with the value at `out`, or 0 when
   the text spells no integer or one outside an I64's range. */
int64_t zane_parse_i64(const zane_text *text, int64_t *out) {
	if (!zane_numeric_text(text, 0)) return 0;
	char *s = zane_terminated(text);
	errno = 0;
	long long value = strtoll(s, NULL, 10);
	int fits = errno != ERANGE;
	free(s);
	if (!fits) return 0;
	*out = (int64_t)value;
	return 1;
}

/* `parseF64` on `@primitives$String`: 1 with the nearest double at `out`,
   rounding half to even, or 0 when the text spells no number or one too
   large to round to a finite double. Read in the C numeric locale, as
   floats are formatted. */
int64_t zane_parse_f64(const zane_text *text, double *out) {
	if (!zane_numeric_text(text, 1)) return 0;
	if (pthread_once(&zane_numeric_once, zane_numeric_init))
		zane_broken("initializing the numeric locale");
	char *s = zane_terminated(text);
#ifdef _WIN32
	double value = _strtod_l(s, NULL, zane_numeric_locale);
#else
	locale_t previous = uselocale(zane_numeric_locale);
	if (!previous) zane_broken("selecting the numeric locale");
	double value = strtod(s, NULL);
	if (!uselocale(previous)) zane_broken("restoring the numeric locale");
#endif
	free(s);
	if (!isfinite(value)) return 0;
	*out = value;
	return 1;
}

/* `@runtime$Runtime`'s `arguments` (effects.md §6.6): a new list of the
   program's arguments, each a string that owns a copy of its bytes. The
   list's block is as big as `zane_list_push` would have grown it to, and
   it and the strings' bytes are in the current scope's region, where the
   list then arrives in its place as any made value does. */
void zane_arguments(zane_list *out) {
	*out = (zane_list){ NULL, 0, 0 };
	if (zane_argc == 0) return;
	int64_t stride = (int64_t)sizeof(zane_text);
	int64_t room = 128;
	while (room < zane_argc * stride) room *= 2;
	zane_text *items = (zane_text *)zane_alloc(zane_here(), room, ZANE_LINE);
	for (int i = 0; i < zane_argc; i++) {
		int64_t length = (int64_t)strlen(zane_argv[i]);
		if (length == 0) {
			items[i] = (zane_text){ "", 0, 0 };
			continue;
		}
		char *bytes = zane_alloc(zane_here(), length, 8);
		memcpy(bytes, zane_argv[i], (size_t)length);
		items[i] = (zane_text){ bytes, length, length };
	}
	*out = (zane_list){ (char *)items, zane_argc, room };
}
