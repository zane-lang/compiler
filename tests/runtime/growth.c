/* A list's oversized block grows in place (memory.md §3.6): once it passes
   1 MiB it lies at the start of a reservation of addresses, and each
   doubling makes more of it usable rather than moving the elements. An
   oversized block made without one, by a copy, moves into one at its next
   doubling. Where the reservation cannot be made, the block is reserved
   alone and each doubling moves it, as a smaller block's does. A block
   moved out of gives its memory back, so a list never holds its old
   elements' bytes beside its new ones. A list's block that is ended, as
   an overwrite ends the list it replaces, waits on its scope's stack, and
   the next block past 1 MiB there grows into it, as a drained list's
   reservation waits for the next list of its context, up to a budget. */

#include "walks.h"

/* ASan reserves shadow address space, so a cap on addresses would fail its
   mappings rather than the reservation; keep the other checks without it. */
#if defined(__SANITIZE_ADDRESS__)
#define ZANE_TEST_ASAN 1
#elif defined(__has_feature)
#if __has_feature(address_sanitizer)
#define ZANE_TEST_ASAN 1
#endif
#endif

#if defined(__linux__) && !defined(ZANE_TEST_ASAN)
#include <sys/resource.h>
#include <sys/wait.h>
#endif

#include "system.h"

#ifndef _WIN32
#include <stdint.h>
#include <sys/mman.h>
#endif

static void check(int ok) { puts(ok ? "yes" : "no"); }

/* The elements that fill 1 MiB, the first oversized size, 32 MiB, and
   64 MiB, the most the first oversized block's reservation holds. */
enum { SMALL = 1 << 17, LARGE = 1 << 22, FULL = 1 << 23 };

static void fill(zane_list *list, int64_t to) {
	for (int64_t i = list->count + 1; i <= to; i++) *(int64_t *)zane_list_push(list, sizeof(int64_t)) = i;
}

static int intact(const zane_list *list, int64_t count) {
	if (list->count != count) return 0;
	for (int64_t i = 0; i < count; i++)
		if (((const int64_t *)list->items)[i] != i + 1) return 0;
	return 1;
}

static zane_list *new_list(zane_mark *scope) {
	zane_list *list = test_slot(scope, sizeof *list, 8, &ints_type);
	zane_list_new(list);
	return list;
}

/* Every chunk the block grew into is the scope's, and none is once it
   drains. */
static void exercise_in_place(void) {
	zane_mark *scope = zane_scope_enter(0);
	zane_list *list = new_list(scope);
	fill(list, SMALL);
	char *block = list->items;
	check(list->room == ZANE_CHUNK);
	fill(list, LARGE);
	char *last = list->items + (LARGE - 1) * sizeof(int64_t);
	check(list->items == block && list->room == (int64_t)LARGE * 8 && intact(list, LARGE));
	check(zane_region_at(block) == scope && zane_region_at(last) == scope);
	zane_scope_drain(scope);
	check(zane_blocks() == 0 && *zane_page(block, 0) == 0 && *zane_page(last, 0) == 0);
}

/* A copy's oversized block takes a reservation as a growing list's does
   (zane_alloc_held), so it grows in place from its first doubling. */
static void exercise_copy(void) {
	zane_mark *scope = zane_scope_enter(0);
	zane_list *list = new_list(scope);
	fill(list, SMALL);
	zane_list *copy = new_list(scope);
	*copy = *list;
	zane_copy((char *)copy, &ints_type);
	char *copied = copy->items;
	fill(copy, SMALL + 1);
	char *moved = copy->items;
	fill(copy, 4 * SMALL);
	check(moved == copied && copy->items == moved && intact(copy, 4 * SMALL) && intact(list, SMALL));
	zane_scope_drain(scope);
	check(zane_blocks() == 0);
}

#ifdef __linux__
/* The lines of /proc/self/smaps for the mappings that meet [lo, hi), on
   stderr. */
static void smaps_around(uintptr_t lo, uintptr_t hi) {
	FILE *f = fopen("/proc/self/smaps", "r");
	if (!f) return;
	char line[512];
	int in = 0;
	while (fgets(line, sizeof line, f)) {
		unsigned long start, end;
		if (sscanf(line, "%lx-%lx ", &start, &end) == 2)
			in = start < hi && end > lo;
		if (in) fputs(line, stderr);
	}
	fclose(f);
}

#endif

/* Whether none of the pages from `at`, `bytes` long, holds memory of its
   own. On Linux, in /proc/self/pagemap, a page a table maps has bit 63 set,
   and one mapped to this process alone bit 56: a given-back page that is
   read again maps the system's shared zero page, present but not exclusive,
   and smaps' Rss does not count it; the runners' kernels show such pages,
   so presence alone is not asked. On macOS `mincore` says whether a page is
   in memory, and on Windows `VirtualQuery` whether it is committed. */
static int given_back(char *at, size_t bytes) {
	size_t page = zane_page_bytes(), pages = bytes / page;
	unsigned char *resident = malloc(pages);
	if (!resident) return 0;
#ifdef _WIN32
	for (size_t i = 0; i < pages;) {
		MEMORY_BASIC_INFORMATION info;
		if (!VirtualQuery(at + i * page, &info, sizeof info)) {
			free(resident);
			return 0;
		}
		size_t run = ((char *)info.BaseAddress + info.RegionSize - (at + i * page)) / page;
		for (size_t k = 0; k < run && i < pages; k++, i++) resident[i] = info.State == MEM_COMMIT;
	}
#elif defined(__APPLE__)
	char *vector = malloc(pages);
	int asked = vector && mincore(at, pages * page, vector) == 0;
	for (size_t i = 0; asked && i < pages; i++) resident[i] = (unsigned char)(vector[i] & MINCORE_INCORE);
	free(vector);
	if (!asked) {
		free(resident);
		return 0;
	}
#else
	uint64_t *entries = malloc(pages * sizeof *entries);
	int map = open("/proc/self/pagemap", O_RDONLY);
	ssize_t want = (ssize_t)(pages * sizeof *entries);
	int read_all = entries && map >= 0 &&
	               pread(map, entries, (size_t)want, (off_t)((uintptr_t)at / page * sizeof *entries)) == want;
	if (map >= 0) close(map);
	if (!read_all) {
		free(entries);
		free(resident);
		return 0;
	}
	for (size_t i = 0; i < pages; i++) resident[i] = (unsigned char)((entries[i] >> 63) & (entries[i] >> 56) & 1);
	free(entries);
#endif
	size_t kept = 0;
	for (size_t i = 0; i < pages; i++) kept += resident[i] & 1;
	/* On stderr, outside the golden output: what stayed, and on Linux the
	   mappings it is in, to tell a page the runtime missed from one the
	   system brought back. */
	if (kept) {
		fprintf(stderr, "given_back: %zu of %zu pages resident from %p:", kept, pages, (void *)at);
		for (size_t i = 0, runs = 0; i < pages && runs < 8;) {
			if (!(resident[i] & 1)) {
				i++;
				continue;
			}
			size_t j = i;
			while (j < pages && (resident[j] & 1)) j++;
			fprintf(stderr, " [%zu, %zu)", i, j);
			i = j;
			runs++;
		}
		fputc('\n', stderr);
#ifdef __linux__
		smaps_around((uintptr_t)at, (uintptr_t)at + pages * page);
#endif
	}
	free(resident);
	return kept == 0;
}

/* A list that outgrows its block's reservation moves into a new one, and
   the pages of the block it left, all but the first, which holds the
   block's header, are given back at once rather than when its scope
   drains. */
static void exercise_move_out(void) {
	zane_mark *scope = zane_scope_enter(0);
	zane_list *list = new_list(scope);
	fill(list, FULL);
	char *block = list->items;
	size_t page = zane_page_bytes();
	char *header = block - ZANE_LINE;
	fill(list, FULL + 1);
	check(list->items != block && intact(list, FULL + 1));
	/* The whole mapping past its header's page, its rounded tail too. */
	check(given_back(header + page, ((zane_mapping *)header)->size - page));
	zane_scope_drain(scope);
	check(zane_blocks() == 0);
}

/* A drained list's reservation stays mapped, and the next list to grow
   past 1 MiB, in a later scope, grows into it. */
static void exercise_warm(void) {
	zane_mark *scope = zane_scope_enter(0);
	zane_list *list = new_list(scope);
	fill(list, 2 * SMALL);
	char *block = list->items;
	zane_scope_drain(scope);
	scope = zane_scope_enter(0);
	list = new_list(scope);
	fill(list, 2 * SMALL);
	check(list->items == block && intact(list, 2 * SMALL));
	zane_scope_drain(scope);
	check(zane_blocks() == 0);
}

/* A list's block past 1 MiB that is ended while its scope is open, as an
   overwrite ends the list it replaces, is where the next list there to
   grow past 1 MiB grows: its pages are still the scope's. */
static void exercise_replaced(void) {
	zane_mark *scope = zane_scope_enter(0);
	zane_list *list = new_list(scope);
	fill(list, 4 * SMALL);
	char *block = list->items;
	zane_end((char *)list, &ints_type);
	zane_list *next = new_list(scope);
	fill(next, 2 * SMALL);
	check(next->items == block && intact(next, 2 * SMALL));
	zane_scope_drain(scope);
	check(zane_blocks() == 0);
}

/* Of several returned blocks a growth could take, it takes the one of its
   own size, so a small list leaves a larger block for a larger request:
   with a 2 MiB block and a 4 MiB one returned, the 4 MiB stack the newer,
   a list growing to 2 MiB takes the 2 MiB block. */
static void exercise_exact_first(void) {
	zane_mark *scope = zane_scope_enter(0);
	zane_list *small = new_list(scope);
	fill(small, 2 * SMALL);
	zane_list *large = new_list(scope);
	fill(large, 4 * SMALL);
	char *wanted = small->items, *other = large->items;
	zane_end((char *)small, &ints_type);
	zane_end((char *)large, &ints_type);
	zane_list *next = new_list(scope);
	fill(next, 2 * SMALL);
	check(next->items == wanted && next->items != other && intact(next, 2 * SMALL));
	zane_scope_drain(scope);
	check(zane_blocks() == 0);
}

/* A returned block whose reservation cannot hold what a new one would
   reserve is passed over: a copy of 32 MiB reserves more addresses than a
   block first made at 2 MiB has. */
static void exercise_too_small(void) {
	zane_mark *scope = zane_scope_enter(0);
	zane_list *large = new_list(scope);
	fill(large, LARGE);
	zane_list *small = new_list(scope);
	fill(small, 2 * SMALL);
	char *block = small->items;
	zane_end((char *)small, &ints_type);
	zane_list *copy = new_list(scope);
	*copy = *large;
	zane_copy((char *)copy, &ints_type);
	check(copy->items != block && intact(copy, LARGE));
	zane_scope_drain(scope);
	check(zane_blocks() == 0);
}

/* A context keeps the reservations of as many lists as one scope drains
   at once, here three, and the next three lists grow into them. */
static void exercise_warm_several(void) {
	zane_mark *scope = zane_scope_enter(0);
	char *blocks[3];
	for (int i = 0; i < 3; i++) {
		zane_list *list = new_list(scope);
		fill(list, 2 * SMALL);
		blocks[i] = list->items;
	}
	zane_scope_drain(scope);
	check(zane_self->span_count >= 3);
	scope = zane_scope_enter(0);
	int reused = 0;
	for (int i = 0; i < 3; i++) {
		zane_list *list = new_list(scope);
		fill(list, 2 * SMALL);
		for (int j = 0; j < 3; j++) reused += list->items == blocks[j];
	}
	check(reused == 3);
	zane_scope_drain(scope);
	check(zane_blocks() == 0);
}

/* A context keeps at most ZANE_WARM_SPANS reservations, however small:
   of one more lists than that, drained at once, the one its scope gave
   back first, the newest, goes back to make room. The context gives back
   what earlier exercises left it first, so every list starts a span of
   3 MiB and the byte budget never binds. */
static void exercise_warm_count(void) {
	zane_give_spares(zane_self);
	zane_mark *scope = zane_scope_enter(0);
	char *newest = NULL;
	for (int i = 0; i <= ZANE_WARM_SPANS; i++) {
		zane_list *list = new_list(scope);
		fill(list, 2 * SMALL);
		newest = list->items;
	}
	zane_scope_drain(scope);
	zane_context *c = zane_self;
	int kept = 0;
	for (zane_mapping *m = c->spans; m; m = m->next) kept += (char *)m == newest - ZANE_LINE;
	check(c->span_count == ZANE_WARM_SPANS && kept == 0);
	check(zane_blocks() == 0);
}

/* An unbounded pool's reservation lists one chunk however much of it was
   touched, so the byte budget cannot count it: a context keeps at most
   ZANE_WARM_POOLS of them, charged nothing. Of three drained at once, two
   stay. */
static void exercise_warm_pools(void) {
	zane_give_spares(zane_self);
	zane_mark *scope = zane_scope_enter(0);
	for (int i = 0; i < 3; i++) *zane_alloc_unbounded(scope) = 1;
	zane_scope_drain(scope);
	zane_context *c = zane_self;
	check(c->span_count == ZANE_WARM_POOLS && c->span_bytes == 0);
	zane_give_spares(c);
	check(zane_blocks() == 0);
}

/* A list growing past 1 MiB takes no kept pool's reservation, though it
   holds enough addresses: the pool's touched pages past the list would
   then go uncounted. */
static void exercise_pool_not_listed(void) {
	zane_give_spares(zane_self);
	zane_mark *scope = zane_scope_enter(0);
	*zane_alloc_unbounded(scope) = 1;
	zane_scope_drain(scope);
	zane_context *c = zane_self;
	scope = zane_scope_enter(0);
	zane_list *list = new_list(scope);
	fill(list, 2 * ZANE_CHUNK / (int64_t)sizeof(int64_t));
	check(c->span_count == 1 && c->span_bytes == 0);
	zane_scope_drain(scope);
	zane_give_spares(c);
	check(zane_blocks() == 0);
}

/* The reservations a context keeps hold at most ZANE_WARM_SPAN_BYTES
   usable bytes, the ones kept longest going back first: of three lists of
   32 MiB, only the one its scope gave back last stays, which is the first
   made, since a scope gives its blocks back newest first. Whether a later
   list lands at an old address says nothing, as the system may map a
   released range there again. */
static void exercise_warm_budget(void) {
	zane_mark *scope = zane_scope_enter(0);
	char *first = NULL;
	for (int i = 0; i < 3; i++) {
		zane_list *list = new_list(scope);
		fill(list, LARGE);
		if (!first) first = list->items;
	}
	zane_scope_drain(scope);
	zane_context *c = zane_self;
	check(c->span_count == 1 && c->span_bytes <= ZANE_WARM_SPAN_BYTES && (char *)c->spans == first - ZANE_LINE);
	check(zane_blocks() == 0);
}

#if defined(__linux__) && !defined(ZANE_TEST_ASAN)
/* With too few addresses for a reservation, the block still grows, by
   moving. The child's limit leaves room for the main context's range and
   for the lists, not for a reservation 64 times a block. */
static int without_reservation(void) {
	fflush(stdout);
	pid_t child = fork();
	if (child == 0) {
		zane_give_spares(zane_self);
		struct rlimit limit;
		if (getrlimit(RLIMIT_AS, &limit) != 0) _exit(2);
		rlim_t budget = (rlim_t)96 * 1024 * 1024 + (rlim_t)(zane_self->limit + ZANE_GUARD - zane_self->base);
		if (limit.rlim_cur > budget) limit.rlim_cur = budget;
		if (setrlimit(RLIMIT_AS, &limit) != 0) _exit(2);
		zane_mark *scope = zane_scope_enter(0);
		zane_list *list = new_list(scope);
		fill(list, 2 * SMALL);
		char *block = list->items;
		fill(list, 8 * SMALL);
		int ok = list->items != block && intact(list, 8 * SMALL);
		zane_scope_drain(scope);
		_exit(ok && zane_blocks() == 0 ? 0 : 1);
	}
	int status;
	return child > 0 && waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

/* The addresses the process holds now, as RLIMIT_AS counts them. */
static rlim_t addresses_held(void) {
	FILE *f = fopen("/proc/self/statm", "r");
	unsigned long pages = 0;
	if (!f) return 0;
	if (fscanf(f, "%lu", &pages) != 1) pages = 0;
	fclose(f);
	return (rlim_t)pages * zane_page_bytes();
}

/* With the addresses a drained list's kept reservation holds all that is
   left, a block that reservation cannot hold is still made: the kept one
   goes back to the system first. The child may take 2 MiB more addresses
   than it holds, less than the 5 MiB copy needs. */
static int reserving_gives_back(void) {
	fflush(stdout);
	pid_t child = fork();
	if (child == 0) {
		zane_give_spares(zane_self);
		zane_mark *outer = zane_scope_enter(0);
		zane_list *source = new_list(outer);
		fill(source, 4 * SMALL);
		zane_mark *inner = zane_scope_enter(0);
		fill(new_list(inner), 2 * SMALL);
		zane_scope_drain(inner);
		struct rlimit limit;
		if (getrlimit(RLIMIT_AS, &limit) != 0) _exit(2);
		rlim_t held = addresses_held();
		if (!held) _exit(2);
		if (limit.rlim_cur > held + ((rlim_t)2 << 20)) limit.rlim_cur = held + ((rlim_t)2 << 20);
		if (setrlimit(RLIMIT_AS, &limit) != 0) _exit(2);
		zane_mark *scope = zane_scope_enter(0);
		zane_list *copy = new_list(scope);
		*copy = *source;
		zane_copy((char *)copy, &ints_type);
		int ok = intact(copy, 4 * SMALL);
		zane_scope_drain(scope);
		zane_scope_drain(outer);
		_exit(ok && zane_blocks() == 0 ? 0 : 1);
	}
	int status;
	return child > 0 && waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0;
}
#endif

void zane_main(void) {
	exercise_in_place();
	exercise_copy();
	exercise_move_out();
	exercise_warm();
	exercise_replaced();
	exercise_exact_first();
	exercise_too_small();
	exercise_warm_several();
	exercise_warm_count();
	exercise_warm_pools();
	exercise_pool_not_listed();
	exercise_warm_budget();
#if defined(__linux__) && !defined(ZANE_TEST_ASAN)
	check(without_reservation());
	check(reserving_gives_back());
#else
	check(1);
	check(1);
#endif
}
