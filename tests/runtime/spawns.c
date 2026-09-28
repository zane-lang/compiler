/* The runtime's spawned calls, tested in C on their own (docs/lowering.md
   L17): frames, the pool, joins and the water tower, over hand-written
   frames of the shape lowering makes. Each check prints `yes` when it holds
   and `no` when it does not. */

#include "zane_internal.h"

static void check(int ok) { puts(ok ? "yes" : "no"); }

static const int64_t text_layout[] = {
	2,
	ZANE_HOST, 0, sizeof(zane_text), 0, 0, 0,
	ZANE_TEXT, 0, sizeof(zane_text), 0, 0, 0,
};

/* A frame: room for the result, then the arguments. */
typedef struct {
	zane_text result;
	const zane_text *left, *right;
} joining;

typedef struct {
	int64_t result;
	int64_t n;
} counting;

/* A spawned `+` on two strings: the result's bytes are the call's own. */
static void join_texts(char *frame) {
	joining *f = (joining *)frame;
	zane_text_join(&f->result, f->left, f->right);
}

/* The sum from 1 to `n`, one scope and one block per step, all returned. */
static void count(char *frame) {
	counting *f = (counting *)frame;
	int64_t sum = 0;
	for (int64_t i = 1; i <= f->n; i++) {
		int64_t scope = zane_scope_enter();
		int64_t *at = zane_slot(scope, sizeof *at, 8, NULL);
		*at = i;
		sum += *at;
		zane_free(zane_box(8, 8), 8, 8);
		zane_scope_drain(scope);
	}
	f->result = sum;
}

/* A call that spawns two of its own and adds what they return. */
static void halves(char *frame) {
	counting *f = (counting *)frame;
	int64_t scope = zane_scope_enter();
	counting *a = zane_frame(scope, sizeof *a, 8), *b = zane_frame(scope, sizeof *b, 8);
	int64_t *ra = zane_slot(scope, 8, 8, NULL), *rb = zane_slot(scope, 8, 8, NULL);
	a->n = f->n;
	b->n = f->n * 2;
	zane_spawn((char *)a, count, (char *)ra, NULL, 8);
	zane_spawn((char *)b, count, (char *)rb, NULL, 8);
	zane_join((char *)a);
	zane_join((char *)b);
	f->result = *ra + *rb;
	zane_scope_drain(scope);
}

/* Two words written back together, over and over, and a reader that
   counts the snapshots in which they differ. */
typedef struct {
	int64_t a, b;
} pair;

typedef struct {
	int64_t result;
	pair *at;
} watching;

enum { ROUNDS = 200000 };

static void write_pairs(char *frame) {
	watching *f = (watching *)frame;
	for (int64_t i = 1; i <= ROUNDS; i++) {
		pair copy = { i, i };
		zane_writeback((char *)f->at, (char *)&copy, sizeof copy, NULL);
	}
}

static void read_pairs(char *frame) {
	watching *f = (watching *)frame;
	int64_t torn = 0;
	for (int64_t i = 0; i < ROUNDS; i++) {
		pair seen;
		zane_snapshot((char *)&seen, (const char *)f->at, sizeof seen);
		torn += seen.a != seen.b;
	}
	f->result = torn;
}

static int holds(const zane_text *t, const char *s) {
	return t->length == (int64_t)strlen(s) && memcmp(t->bytes, s, strlen(s)) == 0;
}

void zane_main(void) {
	zane_text ab = { 0, "ab", 2, 0 }, cd = { 0, "cd", 2, 0 };

	/* A result comes home when it is read: its bytes move into the
	   region of the scope that holds the slot, and the call's context is
	   back in the pool. */
	int64_t scope = zane_scope_enter();
	joining *f = zane_frame(scope, sizeof *f, 8);
	zane_text *home = zane_slot(scope, sizeof(zane_text), 8, text_layout);
	f->left = &ab;
	f->right = &cd;
	zane_spawn((char *)f, join_texts, (char *)home, text_layout, sizeof(zane_text));
	check(zane_self->shared == 1);
	zane_join((char *)f);
	check(holds(home, "abcd") && zane_region_at(home->bytes) == zane_mark_at(zane_self, scope));
	check(zane_self->shared == 0 && zane_blocks == 1);
	zane_join((char *)f);
	check(zane_blocks == 1);
	zane_scope_drain(scope);
	check(zane_blocks == 0);

	/* A result never read comes home at the drain, which then returns
	   its blocks. */
	scope = zane_scope_enter();
	f = zane_frame(scope, sizeof *f, 8);
	home = zane_slot(scope, sizeof(zane_text), 8, text_layout);
	f->left = &cd;
	f->right = &ab;
	zane_spawn((char *)f, join_texts, (char *)home, text_layout, sizeof(zane_text));
	zane_scope_drain(scope);
	check(zane_blocks == 0 && zane_self->shared == 0);

	/* Many calls at once, each in scopes of its own, and calls that spawn
	   calls: every result is right, and contexts are reused. */
	enum { CALLS = 64 };
	scope = zane_scope_enter();
	counting *calls[CALLS];
	int64_t *sums[CALLS];
	for (int i = 0; i < CALLS; i++) {
		calls[i] = zane_frame(scope, sizeof *calls[i], 8);
		sums[i] = zane_slot(scope, 8, 8, NULL);
		calls[i]->n = 100 + i;
		zane_spawn((char *)calls[i], i % 2 ? count : halves, (char *)sums[i], NULL, 8);
	}
	zane_scope_drain(scope);
	int right = 1;
	for (int64_t i = 0; i < CALLS; i++) {
		int64_t n = 100 + i, once = n * (n + 1) / 2, twice = 2 * n * (2 * n + 1) / 2;
		right &= *sums[i] == (i % 2 ? once : once + twice);
	}
	check(right && zane_blocks == 0);
	int32_t made = zane_context_count;
	for (int round = 0; round < 100; round++) {
		scope = zane_scope_enter();
		counting *c = zane_frame(scope, sizeof *c, 8);
		int64_t *sum = zane_slot(scope, 8, 8, NULL);
		c->n = 3;
		zane_spawn((char *)c, count, (char *)sum, NULL, 8);
		zane_join((char *)c);
		right &= *sum == 6;
		zane_scope_drain(scope);
	}
	check(right && zane_context_count == made);

	/* The pool resized while it runs: a count below one is refused, and
	   calls still finish on one thread and on many. */
	check(zane_set_threads(0) == 0 && zane_wanted == zane_processors());
	for (int64_t threads = 1; threads <= 8; threads *= 8) {
		check(zane_set_threads(threads) == 1);
		scope = zane_scope_enter();
		for (int i = 0; i < CALLS; i++) {
			calls[i] = zane_frame(scope, sizeof *calls[i], 8);
			sums[i] = zane_slot(scope, 8, 8, NULL);
			calls[i]->n = i;
			zane_spawn((char *)calls[i], halves, (char *)sums[i], NULL, 8);
		}
		zane_scope_drain(scope);
		for (int64_t i = 0; i < CALLS; i++) right &= *sums[i] == i * (i + 1) / 2 + i * (2 * i + 1);
		check(right && zane_wanted == threads);
	}
	zane_set_threads_auto();
	check(zane_wanted == zane_processors());

	/* A reader never sees a write-back half done. */
	zane_set_threads(2);
	scope = zane_scope_enter();
	pair *shared = zane_slot(scope, sizeof *shared, 8, NULL);
	watching *writer = zane_frame(scope, sizeof *writer, 8);
	watching *reader = zane_frame(scope, sizeof *reader, 8);
	int64_t *torn = zane_slot(scope, 8, 8, NULL);
	writer->at = reader->at = shared;
	zane_spawn((char *)writer, write_pairs, (char *)writer, NULL, 0);
	zane_spawn((char *)reader, read_pairs, (char *)torn, NULL, 8);
	zane_scope_drain(scope);
	check(*torn == 0 && shared->a == ROUNDS && shared->b == ROUNDS);
}
