#include "zane_internal.h"

#include <inttypes.h>
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

/* A scalar's String constructor. The spelling is the shortest decimal that
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

static int zane_format_f32(char *buffer, size_t room, float value) {
	if (isnan(value)) return snprintf(buffer, room, "nan");
	if (isinf(value)) return snprintf(buffer, room, signbit(value) ? "-inf" : "inf");
	for (int precision = 1; precision <= 9; precision++) {
		int length = snprintf(buffer, room, "%.*g", precision, (double)value);
		if (length < 0 || (size_t)length >= room) zane_broken("formatting an F32");
		char *end;
		float round = strtof(buffer, &end);
		if (*end == '\0' && zane_same_f32(value, round)) return length;
	}
	zane_broken("formatting an F32");
	return 0;
}

static int zane_format_f64(char *buffer, size_t room, double value) {
	if (isnan(value)) return snprintf(buffer, room, "nan");
	if (isinf(value)) return snprintf(buffer, room, signbit(value) ? "-inf" : "inf");
	for (int precision = 1; precision <= 17; precision++) {
		int length = snprintf(buffer, room, "%.*g", precision, value);
		if (length < 0 || (size_t)length >= room) zane_broken("formatting an F64");
		char *end;
		double round = strtod(buffer, &end);
		if (*end == '\0' && zane_same_f64(value, round)) return length;
	}
	zane_broken("formatting an F64");
	return 0;
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
	zane_text_from_buffer(out, buffer, zane_format_f32(buffer, sizeof buffer, value));
}

void zane_text_f64(zane_text *out, double value) {
	char buffer[64];
	zane_text_from_buffer(out, buffer, zane_format_f64(buffer, sizeof buffer, value));
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
