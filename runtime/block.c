/* Copyright (C) 2026 The Zane Authors

   This file is part of the Zane runtime library. It is governed by the GNU
   General Public License, version 3, along with the Zane Compiler Runtime
   Library Exception; the compiler's LICENSE, at the root of its source and
   in share/ of its releases, holds both. */

#include "zane_internal.h"

#include <errno.h>
#include <inttypes.h>
#include <locale.h>
#include <math.h>

#ifdef __APPLE__
#include <xlocale.h>
#endif

/* ---------------------------------------------------------------------- */
/* Dynamic blocks (memory.md §3.6, docs/design/lowering.md §9)                   */
/* ---------------------------------------------------------------------- */

void zane_work_start(zane_work *w) {
	w->jobs = w->local;
	w->count = 0;
	w->room = ZANE_LOCAL_JOBS;
}

/* A work out of room: one zeroed whole starts, and one full moves to a heap
   buffer twice the size. Kept out of line, so the push stays small enough
   that every clang inlines it. */
void zane_work_grow(zane_work *w) {
	if (w->room == 0) {
		zane_work_start(w);
		return;
	}
	int64_t room = 2 * w->room;
	zane_job *jobs = w->jobs == w->local ? malloc((size_t)room * sizeof *jobs)
	                                     : realloc(w->jobs, (size_t)room * sizeof *jobs);
	if (!jobs) zane_broken("out of memory for a value's blocks");
	if (w->jobs == w->local) memcpy(jobs, w->local, sizeof w->local);
	w->jobs = jobs;
	w->room = room;
}

void zane_work_end(zane_work *w) {
	if (w->jobs != w->local) free(w->jobs);
	zane_work_start(w);
}

/* A walk handed on, to run once the walk handing it on is done. */
void zane_defer(zane_work *work, zane_walk walk, char *at, char *with, int64_t extra) {
	zane_work_push(work, (zane_job){ .walk = walk, .at = at, .with = with, .extra = extra });
}

/* A block to return once the jobs handed on after it are done: those for
   what lives in it. */
void zane_defer_return(zane_work *work, char *block, int64_t size, int64_t align) {
	zane_work_push(work, (zane_job){ .at = block, .extra = size, .align = align });
}

/* Every job handed on, last first, each of which may hand on more. */
void zane_work_run(zane_work *w) {
	zane_job job;
	while (zane_work_pop(w, &job)) {
		if (job.walk) job.walk(job.at, job.with, job.extra, w, 0);
		else zane_free(job.at, job.extra, job.align);
	}
	zane_work_end(w);
}

/* The value at `base` dies: each block it owns is returned, down through
   the blocks inside them (lifetimes.md §2.1). A type that owns none has no
   walks, and is no type here. */
void zane_end(char *base, const zane_type *type) {
	if (!type) return;
	zane_work w;
	zane_work_start(&w);
	type->end(base, NULL, 0, &w, 0);
	zane_work_run(&w);
}

/* The scope a value is made in is the innermost; where it arrives decides
   where its blocks end up. */
static zane_mark *zane_here(void) { return zane_self->top; }

/* The value at `value` was copied from another place: each block it names
   is still the original's, so it gets a copy of its own, down through the
   blocks inside it (memory.md §2.3), all in the innermost region. */
void zane_copy(char *value, const zane_type *type) {
	if (!type) return;
	zane_mark *region = zane_here();
	zane_work w;
	zane_work_start(&w);
	zane_check_region(region);
	type->copy(value, (char *)region, 0, &w, 0);
	zane_work_run(&w);
}

/* A boxed member's block (memory.md §3.6): exactly one payload's size. */
void *zane_box(int64_t size, int64_t align) { return zane_box_in(zane_here(), size, align); }

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

void zane_text_bytes(zane_text *out, const zane_list *bytes) {
	int64_t n = ZL_COUNT(bytes);
	if (n <= 0) {
		*out = (zane_text){ "", 0, 0 };
		return;
	}
	char *copy = zane_alloc(zane_here(), n, 8);
	memcpy(copy, ZL_ITEMS(bytes), (size_t)n);
	*out = (zane_text){ copy, n, n };
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
	zane_output(text->bytes, (size_t)text->length);
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

/* The blocks `zane_bytes_alloc` gave C on this thread for strings it
   returns (spec ffi.md §3.5, docs/design/ffi.md F10), oldest first. Each
   foreign call that returns a string holds the count it began at, its
   mark, so a call reached from a function value C called, inside another,
   keeps its own blocks. When a call returns, its last block is taken when
   the view starts there and fits in it, and every other block it was
   given goes back to its region, since C keeps none of them. */
typedef struct {
	char *block;
	int64_t size;
} zane_given_block;

static _Thread_local struct {
	zane_given_block *blocks;
	int64_t count, room;
} zane_given;

/* [*items], of [room] items of [size] bytes, with room for one more. */
static void *zane_given_grow(void *items, int64_t *room, int64_t count, size_t size) {
	if (count < *room) return items;
	int64_t more = *room ? *room * 2 : 8;
	void *grown = realloc(items, (size_t)more * size);
	if (!grown) zane_broken("out of memory for the strings C allocates");
	*room = more;
	return grown;
}

/* `<zane_ffi.h>`'s allocator: `size` bytes in the region the foreign
   call's string result is made in, for C to write and return. */
uint8_t *zane_bytes_alloc(size_t size) {
	static uint8_t none[1];
	if (!zane_self) zane_broken("zane_bytes_alloc called on a thread no foreign call runs on");
	if (size > (size_t)INT64_MAX / 2) zane_broken("out of memory for a string C allocates");
	if (size == 0) return none;
	char *block = zane_alloc(zane_here(), (int64_t)size, 8);
	zane_given.blocks = zane_given_grow(zane_given.blocks, &zane_given.room, zane_given.count, sizeof *zane_given.blocks);
	zane_given.blocks[zane_given.count++] = (zane_given_block){ block, (int64_t)size };
	return (uint8_t *)block;
}

/* Before a foreign call that returns a string: the mark its blocks begin
   at. It changes nothing, so a call whose result a fold made a constant
   leaves no state behind. */
int64_t zane_text_expect(void) { return zane_given.count; }

/* A string C returned, as the view it gave: the call's last block taken
   as it is when the view starts there and fits in it, and otherwise its
   bytes copied into a block of the string's own; the call's other blocks
   returned: those from [mark], what `zane_text_expect` gave before it. */
void zane_text_taken(zane_text *out, const zane_text *view, int64_t mark) {
	if (mark < 0 || mark > zane_given.count) mark = zane_given.count;
	int64_t taken = -1;
	if (zane_given.count > mark) {
		zane_given_block last = zane_given.blocks[zane_given.count - 1];
		if (view->length > 0 && view->bytes == last.block && view->length <= last.size) {
			*out = (zane_text){ last.block, view->length, last.size };
			taken = zane_given.count - 1;
		}
	}
	if (taken < 0) {
		static const zane_text empty = { "", 0, 0 };
		zane_text_join(out, view, &empty);
	}
	for (int64_t i = mark; i < zane_given.count; i++)
		if (i != taken) zane_free(zane_given.blocks[i].block, zane_given.blocks[i].size, 8);
	zane_given.count = mark;
}

/* `==` on `@primitives$String`: the same bytes. */
int64_t zane_text_equal(const zane_text *left, const zane_text *right) {
	return left->length == right->length &&
	       (left->length == 0 || memcmp(left->bytes, right->bytes, (size_t)left->length) == 0);
}

/* Whether a string spells an integer as `parseI64` reads one (types.md
   §2.10): a literal's digits with an optional `-` first. */
static int zane_integer_text(const zane_text *text) {
	int64_t n = text->length, i = 0;
	const char *b = text->bytes;
	if (n > 0 && b[0] == '-') i++;
	int64_t start = i;
	while (i < n && b[i] >= '0' && b[i] <= '9') i++;
	return i > start && i == n;
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
	if (!zane_integer_text(text)) return 0;
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
   large to round to a finite double. A number is a literal's digits with
   an optional `-` first and an optional `.` with digits on both sides
   (types.md §2.10). Read in the C numeric locale, as floats are
   formatted. */
int64_t zane_parse_f64(const zane_text *text, double *out) {
	/* The text is checked and its
	   digits folded in one pass, then Clinger's fast path. With at most 19
	   digits the
	   digits fold into a u64 exactly; up to 2^53 that integer is an exact
	   double (converted as an i64, one instruction on x86-64), and so is
	   10^k for k <= 22, so the one division is the one rounding and gives
	   the nearest double. Anything else is read by the C library. */
	static const double pow10[] = {1e0,  1e1,  1e2,  1e3,  1e4,  1e5,  1e6,  1e7,
	                               1e8,  1e9,  1e10, 1e11, 1e12, 1e13, 1e14, 1e15,
	                               1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22};
	{
		const unsigned char *b = (const unsigned char *)text->bytes;
		int64_t n = text->length, i = n > 0 && b[0] == '-';
		int negative = (int)i;
		int64_t start = i;
		uint64_t mantissa = 0;
		while (i < n && (unsigned)(b[i] - '0') < 10) mantissa = mantissa * 10 + (b[i++] - '0');
		int64_t whole = i - start, fraction = 0;
		if (whole > 0 && i < n && b[i] == '.') {
			int64_t point = ++i;
			while (i < n && (unsigned)(b[i] - '0') < 10) mantissa = mantissa * 10 + (b[i++] - '0');
			fraction = i - point;
			if (fraction == 0) return 0;
		}
		if (whole == 0 || i != n) return 0;
		if (whole + fraction <= 19 && fraction <= 22 && mantissa <= (UINT64_C(1) << 53)) {
			double value = (double)(int64_t)mantissa / pow10[fraction];
			*out = negative ? -value : value;
			return 1;
		}
	}
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

/* `parseF64At` on
   `@primitives$String`: `parseF64` on the `count` bytes from byte `start`,
   counted from 1 as `byteAt` counts; a range outside the text is out of
   range. */
int64_t zane_parse_f64_at(const zane_text *text, double *out, int64_t start, int64_t count) {
	if (start < 1 || count < 0 || count > text->length - (start - 1)) zane_out_of_range();
	zane_text view = {text->bytes + (start - 1), count, 0};
	return zane_parse_f64(&view, out);
}

/* `@runtime$Runtime`'s `arguments` (effects.md §6.6): a new list of the
   program's arguments, each a string that owns a copy of its bytes. The
   list's block is as big as `zane_list_push` would have grown it to, and
   it and the strings' bytes are in the current scope's region, where the
   list then arrives in its place as any made value does. */
void zane_arguments(zane_list *out) {
	*out = ZL_MAKE(NULL, 0, 0);
	if (zane_argc == 0) return;
	int64_t stride = (int64_t)sizeof(zane_text);
	int64_t room = 128;
	while (room < zane_argc * stride) room *= 2;
	/* The handle's room is in its unit (ZL_ELEMENTS), and the block is the
	   bytes of that many whole units. */
	int64_t units = room / zl_unit(stride);
	zane_text *items = (zane_text *)zane_alloc(zane_here(), zl_block_bytes(units, stride), ZANE_LIST_ALIGN);
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
	*out = ZL_MAKE((char *)items, zane_argc, units);
}

/* `findPair` and `findAny`: the first of `count` positions of a string's
   bytes from `at`, counted from 1, whose byte is in the set `first` and
   the byte `gap` after it in `second`, or 0 when there is none. A set is what
   zane_byte_set makes, below: whether each byte is in it, then tables of
   16 where bit k of the j-th of the first stands for the byte k * 16 + j,
   and of the second for 128 + k * 16 + j, by which 16 positions are
   tested at once with SSSE3's byte shuffle, and the cheaper test a set of
   few members, few non-members or one run takes. */
#if defined(__x86_64__)
#include <cpuid.h>
#include <immintrin.h>

/* Whether the processor has SSSE3, asked once (CPUID leaf 1, ECX bit 9). */
static int zane_ssse3 = -1;
static int zane_has_ssse3(void) {
	if (zane_ssse3 < 0) {
		unsigned a, b, c, d;
		zane_ssse3 = __get_cpuid(1, &a, &b, &c, &d) && (c & bit_SSSE3) ? 1 : 0;
	}
	return zane_ssse3;
}

/* The members among x's 16 bytes, by a set's tables: pshufb gives 0 for an index with its top bit set, so lo
   answers for x < 128 and hi, indexed by x ^ 0x80, for the rest; then the
   bit for x's bits 4 to 6. */
__attribute__((target("ssse3"))) static inline __m128i zane_set_test(__m128i x, __m128i lo, __m128i hi) {
	const __m128i bits = _mm_setr_epi8(1, 2, 4, 8, 16, 32, 64, -128, 1, 2, 4, 8, 16, 32, 64, -128);
	__m128i t = _mm_or_si128(_mm_shuffle_epi8(lo, x), _mm_shuffle_epi8(hi, _mm_xor_si128(x, _mm_set1_epi8((char)0x80))));
	__m128i bit = _mm_shuffle_epi8(bits, _mm_and_si128(_mm_srli_epi16(x, 4), _mm_set1_epi8(7)));
	return _mm_cmpeq_epi8(_mm_and_si128(t, bit), bit);
}

/* A set's block test, by its kind (zane_byte_set): a set of 1 to 3 bytes
   (kind 1 to 3) compares with each, a run (4) by its first byte and
   width, others (5) by the tables; `flip` complements. */
typedef struct {
	__m128i a, b, c, flip;
} zane_bsm;

static inline int zane_set_kind(const uint8_t *s) { return s[289]; }

static inline zane_bsm zane_bsm_init(const uint8_t *s, int kind) {
	zane_bsm m;
	if (kind == 5) {
		m.a = _mm_loadu_si128((const __m128i *)(s + 256));
		m.b = _mm_loadu_si128((const __m128i *)(s + 272));
		m.c = m.flip = _mm_setzero_si128();
	} else {
		m.a = _mm_set1_epi8((char)s[291]);
		m.b = _mm_set1_epi8((char)s[292]);
		m.c = _mm_set1_epi8((char)s[293]);
		m.flip = s[290] ? _mm_set1_epi8(-1) : _mm_setzero_si128();
	}
	return m;
}

__attribute__((target("ssse3"), always_inline)) static inline __m128i zane_bsm_test(const zane_bsm *m, int k, __m128i x) {
	__m128i r;
	if (k == 5) return zane_set_test(x, m->a, m->b);
	if (k == 1) r = _mm_cmpeq_epi8(x, m->a);
	else if (k == 2) r = _mm_or_si128(_mm_cmpeq_epi8(x, m->a), _mm_cmpeq_epi8(x, m->b));
	else if (k == 3) r = _mm_or_si128(_mm_or_si128(_mm_cmpeq_epi8(x, m->a), _mm_cmpeq_epi8(x, m->b)), _mm_cmpeq_epi8(x, m->c));
	else {
		__m128i t = _mm_sub_epi8(x, m->a);
		r = _mm_cmpeq_epi8(_mm_min_epu8(t, m->b), t);
	}
	return _mm_xor_si128(r, m->flip);
}

__attribute__((target("ssse3"), always_inline)) static inline int64_t zane_pair_k(const uint8_t *p, int64_t n, const uint8_t *a, int64_t d,
                                                                                  const uint8_t *b, int ka, int kb) {
	zane_bsm ma = zane_bsm_init(a, ka), mb = zane_bsm_init(b, kb);
	int64_t i = 0;
	for (; i + 16 <= n; i += 16) {
		__m128i x = _mm_loadu_si128((const __m128i *)(p + i)), y = _mm_loadu_si128((const __m128i *)(p + i + d));
		unsigned k = (unsigned)_mm_movemask_epi8(_mm_and_si128(zane_bsm_test(&ma, ka, x), zane_bsm_test(&mb, kb, y)));
		if (k) return i + __builtin_ctz(k);
	}
	if (i == n) return -1;
	/* The last positions: one block ending at the last,
	   its positions already searched shifted out. */
	if (n >= 16) {
		__m128i x = _mm_loadu_si128((const __m128i *)(p + n - 16)), y = _mm_loadu_si128((const __m128i *)(p + n - 16 + d));
		unsigned k = (unsigned)_mm_movemask_epi8(_mm_and_si128(zane_bsm_test(&ma, ka, x), zane_bsm_test(&mb, kb, y))) >> (16 - (n - i));
		return k ? i + __builtin_ctz(k) : -1;
	}
	for (; i < n; i++)
		if (a[p[i]] && b[p[i + d]]) return i;
	return -1;
}

__attribute__((target("ssse3"), always_inline)) static inline int64_t zane_any_k(const uint8_t *p, int64_t n, const uint8_t *a, int ka) {
	zane_bsm ma = zane_bsm_init(a, ka);
	int64_t i = 0;
	for (; i + 16 <= n; i += 16) {
		unsigned k = (unsigned)_mm_movemask_epi8(zane_bsm_test(&ma, ka, _mm_loadu_si128((const __m128i *)(p + i))));
		if (k) return i + __builtin_ctz(k);
	}
	if (i == n) return -1;
	if (n >= 16) {
		unsigned k = (unsigned)_mm_movemask_epi8(zane_bsm_test(&ma, ka, _mm_loadu_si128((const __m128i *)(p + n - 16)))) >> (16 - (n - i));
		return k ? i + __builtin_ctz(k) : -1;
	}
	for (; i < n; i++)
		if (a[p[i]]) return i;
	return -1;
}

#define ZANE_PAIR_ROW(ka) \
	case (ka) * 8 + 1: return zane_pair_k(p, n, a, d, b, ka, 1); \
	case (ka) * 8 + 2: return zane_pair_k(p, n, a, d, b, ka, 2); \
	case (ka) * 8 + 3: return zane_pair_k(p, n, a, d, b, ka, 3); \
	case (ka) * 8 + 4: return zane_pair_k(p, n, a, d, b, ka, 4); \
	case (ka) * 8 + 5: return zane_pair_k(p, n, a, d, b, ka, 5);

__attribute__((target("ssse3"))) static int64_t zane_pair_blocks(const uint8_t *p, int64_t n, const uint8_t *a, int ka, int64_t d,
                                                                 const uint8_t *b, int kb) {
	switch (ka * 8 + kb) {
		ZANE_PAIR_ROW(1) ZANE_PAIR_ROW(2) ZANE_PAIR_ROW(3) ZANE_PAIR_ROW(4)
		default: return zane_pair_k(p, n, a, d, b, 5, 5);
	}
}

__attribute__((target("ssse3"))) static int64_t zane_any_blocks(const uint8_t *p, int64_t n, const uint8_t *a, int ka) {
	switch (ka) {
		case 1: return zane_any_k(p, n, a, 1);
		case 2: return zane_any_k(p, n, a, 2);
		case 3: return zane_any_k(p, n, a, 3);
		case 4: return zane_any_k(p, n, a, 4);
		default: return zane_any_k(p, n, a, 5);
	}
}
#endif

/* A byte set as `findAny` and `findPair` read it, made from `members`, a
   list of 256 flags, byte b's at b + 1. Its 294 bytes: whether each byte
   is in it (0 to 255), the two shuffle tables (256 to 287), then how a
   block of 16 is tested (289): 1 to 3 for that many members compared one
   by one, or that many non-members with the result complemented (290 is
   1), the bytes compared at 291 to 293; 4 for a run of members, its first
   byte at 291 and its width less one at 292; 5 for the tables. */
enum { ZANE_BYTE_SET = 294 };

void zane_byte_set(zane_list *out, const zane_list *members) {
	if (ZL_COUNT(members) != 256) zane_out_of_range();
	const uint8_t *in = (const uint8_t *)ZL_ITEMS(members);
	int64_t units = 512 / zl_unit(1);
	uint8_t *s = (uint8_t *)zane_alloc(zane_here(), zl_block_bytes(units, 1), ZANE_LIST_ALIGN);
	memset(s, 0, ZANE_BYTE_SET);
	int count = 0, lowest = 256, highest = -1;
	for (int b = 0; b < 256; b++) {
		if (!in[b]) continue;
		s[b] = 1;
		s[(b < 128 ? 256 : 272) + (b & 15)] |= (uint8_t)(1 << ((b >> 4) & 7));
		count++;
		if (b < lowest) lowest = b;
		highest = b;
	}
	s[289] = 5;
	if (count > 0 && count < 256) {
		int few = count <= 3, most = 256 - count <= 3;
		if (few || most) {
			int want = few ? 1 : 0, k = 0;
			s[290] = !few;
			for (int b = 0; b < 256; b++)
				if (s[b] == want) s[291 + k++] = (uint8_t)b;
			s[289] = (uint8_t)k;
		} else if (highest - lowest + 1 == count) {
			s[289] = 4;
			s[291] = (uint8_t)lowest;
			s[292] = (uint8_t)(highest - lowest);
		}
	}
	*out = ZL_MAKE((char *)s, ZANE_BYTE_SET, units);
}

/* The same for one set. */
int64_t zane_text_find_any(const zane_text *text, int64_t at, int64_t count, const zane_list *set) {
	if (count <= 0) return 0;
	int64_t from = at - 1;
	if (from < 0 || from + count > text->length || ZL_COUNT(set) != ZANE_BYTE_SET) zane_out_of_range();
	const uint8_t *p = (const uint8_t *)text->bytes + from, *a = (const uint8_t *)ZL_ITEMS(set);
	int64_t r;
#if defined(__x86_64__)
	if (zane_has_ssse3()) {
		r = zane_any_blocks(p, count, a, zane_set_kind(a));
		return r < 0 ? 0 : at + r;
	}
#endif
	for (int64_t i = 0; i < count; i++)
		if (a[p[i]]) return at + i;
	return 0;
}

int64_t zane_text_find_pair(const zane_text *text, int64_t at, int64_t count, const zane_list *first, int64_t gap,
                            const zane_list *second) {
	if (count <= 0) return 0;
	int64_t from = at - 1;
	if (from < 0 || gap < 0 || from + count + gap > text->length || ZL_COUNT(first) != ZANE_BYTE_SET || ZL_COUNT(second) != ZANE_BYTE_SET)
		zane_out_of_range();
	const uint8_t *p = (const uint8_t *)text->bytes + from;
	const uint8_t *a = (const uint8_t *)ZL_ITEMS(first), *b = (const uint8_t *)ZL_ITEMS(second);
	int64_t r;
#if defined(__x86_64__)
	if (zane_has_ssse3()) {
		r = zane_pair_blocks(p, count, a, zane_set_kind(a), gap, b, zane_set_kind(b));
		return r < 0 ? 0 : at + r;
	}
#endif
	for (int64_t i = 0; i < count; i++)
		if (a[p[i]] && b[p[i + gap]]) return at + i;
	return 0;
}

