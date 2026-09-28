#include "zane_internal.h"

/* ---------------------------------------------------------------------- */
/* Anchors and tethers (memory.md §4, docs/lowering.md §9)                */
/* ---------------------------------------------------------------------- */

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

int zane_present(const char *base, const zane_position *p) {
	for (int64_t i = 0; i < p->conditions; i++)
		if (*(const int32_t *)(base + p->tags[2 * i]) != (int32_t)p->tags[2 * i + 1]) return 0;
	return 1;
}

uint32_t *zane_backpointer(char *base, const zane_position *p) {
	return (uint32_t *)(base + p->offset);
}

/* A host that is there, whose identity a caller may read. */
int zane_hosts(const char *base, const zane_position *p) {
	return p->kind == ZANE_HOST && zane_present(base, p);
}

/* Cells are kept in segments, so one stays where it is while others are
   made, and a guest reads its own from any thread. Cells are made and
   retired under a lock. */
static zane_cell *zane_cell_segments[(1ull << 32) / ZANE_CELL_SEGMENT];
static uint32_t zane_cell_count = 1;
static uint32_t zane_free_cell;  /* a stack of returned cells, linked by `sibling` */
pthread_mutex_t zane_anchors = PTHREAD_MUTEX_INITIALIZER;

zane_cell *zane_anchor(uint32_t id) {
	return &zane_cell_segments[id / ZANE_CELL_SEGMENT][id % ZANE_CELL_SEGMENT];
}

/* A new cell; the lock is held. */
static uint32_t zane_new_cell(void *target) {
	uint32_t id = zane_free_cell;
	if (id) {
		zane_free_cell = zane_anchor(id)->sibling;
	} else {
		if (zane_cell_count == UINT32_MAX) zane_broken("out of anchors");
		zane_cell **segment = &zane_cell_segments[zane_cell_count / ZANE_CELL_SEGMENT];
		if (!*segment && !(*segment = malloc(ZANE_CELL_SEGMENT * sizeof **segment)))
			zane_broken("out of memory for anchors");
		id = zane_cell_count++;
	}
	*zane_anchor(id) = (zane_cell){ target, 0, 0, 0 };
	return id;
}

/* A cell retired with its forwarders; the lock is held. */
static void zane_retire_held(uint32_t id) {
	uint32_t f = zane_anchor(id)->forwarders;
	while (f) {
		uint32_t next = zane_anchor(f)->sibling;
		zane_retire_held(f);
		f = next;
	}
	zane_anchor(id)->sibling = zane_free_cell;
	zane_free_cell = id;
}

void zane_retire(uint32_t id) {
	pthread_mutex_lock(&zane_anchors);
	zane_retire_held(id);
	pthread_mutex_unlock(&zane_anchors);
}

/* The identity a tether ends at, following forwarders. */
uint32_t zane_terminal(uint32_t tether) {
	if (tether == 0) zane_broken("an untethered guest");
	while (zane_anchor(tether)->forward) tether = zane_anchor(tether)->forward;
	return tether;
}

/* The address a guest names. */
void *zane_resolve(uint32_t tether) { return zane_anchor(zane_terminal(tether))->target; }

/* A guest to the host at `payload`: its anchor, made the first time. Calls
   running at once may each mint one to a host they read, and get the same. */
uint32_t zane_mint(void *payload) {
	uint32_t *backpointer = payload;
	uint32_t id = __atomic_load_n(backpointer, __ATOMIC_ACQUIRE);
	if (id) return id;
	pthread_mutex_lock(&zane_anchors);
	id = *backpointer;
	if (!id) __atomic_store_n(backpointer, id = zane_new_cell(payload), __ATOMIC_RELEASE);
	pthread_mutex_unlock(&zane_anchors);
	return id;
}
