/* The spare chunks drained regions leave, tested in C on their own
   (docs/design/lowering.md §9): some stay warm, with their pages, and the
   rest turn cold, their pages after the first given back to the system,
   and a cold chunk is reused, its given-back pages reading as zero. Each
   check prints `yes` when it holds and `no` when it does not. */

#include "scopes.h"

static void check(int ok) { puts(ok ? "yes" : "no"); }

/* A block that takes a whole chunk to itself. */
enum { BLOCK = ZANE_CHUNK - ZANE_LINE };

typedef struct {
	zane_task header;
	int64_t result, chunks, depth, cooling;
} spawned;

/* The warm spares the last call kept on its context: just after its drain,
   and after its later drains. */
static int64_t warm_drained, warm_cooled;

/* `chunks` chunks in a scope, each filled, then drained. The result counts
   the chunks whose pages after the first read as zero before the fill. */
static int64_t fill(int64_t chunks) {
	zane_mark *scope = zane_scope_enter(0);
	int64_t zeroed = 0;
	long page = sysconf(_SC_PAGESIZE);
	for (int64_t i = 0; i < chunks; i++) {
		char *block = zane_alloc(scope, BLOCK, 8);
		int zero = 1;
		for (char *at = block - ZANE_LINE + page; at < block + BLOCK; at++)
			if (*at) {
				zero = 0;
				break;
			}
		zeroed += zero;
		memset(block, 0x5a, BLOCK);
	}
	zane_scope_drain(scope);
	return zeroed;
}

/* A spawned call that fills its chunks and drains them `cooling` times
   more, a chunk at a time, then spawns the next deeper one, so that
   `depth` contexts hold their warm spares at once and then go idle one
   after another. */
static void filling(char *frame) {
	spawned *f = (spawned *)(frame - offsetof(spawned, result));
	f->result = fill(f->chunks);
	warm_drained = zane_self->warm;
	for (int64_t i = 0; i < f->cooling; i++) fill(1);
	warm_cooled = zane_self->warm;
	if (f->depth > 0) {
		spawned inner = { .chunks = f->chunks, .depth = f->depth - 1 };
		zane_spawn((char *)&inner.result, filling, NULL, NULL, 0);
		zane_join((char *)&inner.result);
	}
}

static int64_t spawn_fill(int64_t chunks, int64_t depth, int64_t cooling) {
	spawned f = { .chunks = chunks, .depth = depth, .cooling = cooling };
	zane_spawn((char *)&f.result, filling, NULL, NULL, 0);
	zane_join((char *)&f.result);
	return f.result;
}

/* What the process holds in memory, in bytes. */
static int64_t resident(void) {
	FILE *f = fopen("/proc/self/statm", "r");
	long size = 0, pages = 0;
	if (f) {
		if (fscanf(f, "%ld %ld", &size, &pages) != 2) pages = 0;
		fclose(f);
	}
	return (int64_t)pages * sysconf(_SC_PAGESIZE);
}

/* The most a process keeps resident past where it began: the warm spares
   the pool and a context keep, and a few MiB more. */
static const int64_t slack = (int64_t)(ZANE_POOL_WARM + ZANE_WARM_KEPT + 4) * ZANE_CHUNK;

void zane_main(void) {
	zane_set_threads(1);
	spawn_fill(1, 0, 0);
	int64_t before = resident();

	/* 128 chunks filled and drained: the context keeps them warm while it
	   runs, and gives them to the pool when it goes idle, which keeps a few
	   warm; the rest are cold. */
	spawn_fill(128, 0, 0);
	check(warm_drained == 128);
	check(resident() - before <= slack);
	check(zane_warm_spares == ZANE_POOL_WARM && zane_cold_spares == 128 - ZANE_POOL_WARM);

	/* 128 again: the warm ones first, then the cold ones, each reused and
	   reading as zero past its first page. */
	int64_t reuses = zane_cold_reuses;
	check(spawn_fill(128, 0, 0) == 128 - ZANE_POOL_WARM);
	check(zane_cold_reuses - reuses == 128 - ZANE_POOL_WARM);

	/* A context that keeps running keeps a few warm for good, and the rest
	   only until they have sat unused through ZANE_COOLING of its drains. */
	spawn_fill(128, 0, ZANE_COOLING - 1);
	check(warm_cooled > ZANE_WARM_KEPT);
	spawn_fill(128, 0, ZANE_COOLING);
	check(warm_cooled == ZANE_WARM_KEPT);

	/* Eight contexts holding their warm spares at once: the pool keeps at
	   most ZANE_POOL_WARM of them once they are idle. */
	spawn_fill(8, 7, 0);
	check(zane_warm_spares == ZANE_POOL_WARM);

	/* Past ZANE_COLD_KEPT cold chunks, a drained chunk is given back whole. */
	spawn_fill(ZANE_COLD_KEPT + 64, 0, 0);
	check(zane_cold_spares == ZANE_COLD_KEPT);
	check(resident() - before <= slack);
}
