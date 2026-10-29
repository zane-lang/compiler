/* A list's oversized block grows in place (memory.md §3.6): once it passes
   1 MiB it lies at the start of a reservation of addresses, and each
   doubling makes more of it usable rather than moving the elements. An
   oversized block made without one, by a copy, moves into one at its next
   doubling. Where the reservation cannot be made, the block is reserved
   alone and each doubling moves it, as a smaller block's does. A block
   moved out of gives its memory back, so a list never holds its old
   elements' bytes beside its new ones, and a drained list's reservation
   stays mapped for the next list to grow into. */

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

#ifdef __linux__
#include <sys/mman.h>
#include <unistd.h>
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

/* A copy's oversized block is the copy's size alone, so its first doubling
   moves it into a reservation, where the next grows in place. */
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
	check(moved != copied && copy->items == moved && intact(copy, 4 * SMALL) && intact(list, SMALL));
	zane_scope_drain(scope);
	check(zane_blocks() == 0);
}

#ifdef __linux__
/* Whether none of the pages from `at`, `bytes` long, is in memory. */
static int given_back(char *at, size_t bytes) {
	size_t page = (size_t)sysconf(_SC_PAGESIZE), pages = bytes / page;
	unsigned char *resident = malloc(pages);
	if (!resident || mincore(at, pages * page, resident) != 0) return 0;
	int none = 1;
	for (size_t i = 0; i < pages; i++)
		if (resident[i] & 1) none = 0;
	free(resident);
	return none;
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
	size_t page = (size_t)sysconf(_SC_PAGESIZE);
	char *header = block - ZANE_LINE;
	fill(list, FULL + 1);
	check(list->items != block && intact(list, FULL + 1));
	check(given_back(header + page, (size_t)FULL * 8 + ZANE_LINE - page));
	zane_scope_drain(scope);
	check(zane_blocks() == 0);
}
#endif

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
#endif

void zane_main(void) {
	exercise_in_place();
	exercise_copy();
#ifdef __linux__
	exercise_move_out();
#else
	check(1);
	check(1);
	check(1);
#endif
	exercise_warm();
#if defined(__linux__) && !defined(ZANE_TEST_ASAN)
	check(without_reservation());
#else
	check(1);
#endif
}
