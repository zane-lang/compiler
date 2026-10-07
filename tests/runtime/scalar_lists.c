/* Empty element layouts must not build a work queue per scalar (#191).
   The memory budget catches that regression without a timing threshold.
   Null layouts and non-null empty tables must both keep the list's bytes
   intact through copying and promotion, and return its backing block. */

#include "zane_internal.h"

/* ASan reserves shadow address space; retain the ownership checks but
   apply the memory budget only to builds without that reservation. */
#if defined(__SANITIZE_ADDRESS__)
#define ZANE_TEST_ASAN 1
#elif defined(__has_feature)
#if __has_feature(address_sanitizer)
#define ZANE_TEST_ASAN 1
#endif
#endif

#if defined(__linux__) && !defined(ZANE_TEST_ASAN)
#include <sys/resource.h>
#endif

static void check(int ok) { puts(ok ? "yes" : "no"); }

enum { ELEMENTS = 2000000 };
static const int64_t scalar_layout[] = { 0 };
static int64_t list_layout[] = {
	1,
	ZANE_LIST, 0, sizeof(zane_list), sizeof(int64_t), 0, 0,
};
static int64_t box_layout[] = {
	1,
	ZANE_BOX, 0, sizeof(char *), sizeof(int64_t), 0, 0,
};

/* Hold the list in the requested scope so its backing blocks drain with it. */
static zane_list *make_list(int64_t scope) {
	zane_list *list = zane_slot(scope, sizeof *list, 8, list_layout);
	zane_list_new(list);
	for (int64_t i = 1; i <= ELEMENTS; i++)
		*(int64_t *)zane_list_push(list, sizeof(int64_t)) = i;
	return list;
}

/* Check every element after relocation, rather than only the endpoints. */
static int intact(const zane_list *list) {
	if (list->count != ELEMENTS) return 0;
	for (int64_t i = 0; i < ELEMENTS; i++)
		if (((const int64_t *)list->items)[i] != i + 1) return 0;
	return 1;
}

/* Verify ownership through cleanup, independent copying, and scope escape. */
static void exercise_lists(void) {
	int64_t scope = zane_scope_enter();
	zane_list *list = make_list(scope);
	check(intact(list));
	zane_scope_drain(scope);
	check(zane_blocks == 0);

	/* A copy owns a separate block, including when its elements own none. */
	scope = zane_scope_enter();
	list = make_list(scope);
	zane_list *copy = zane_slot(scope, sizeof *copy, 8, list_layout);
	*copy = *list;
	zane_copy((char *)copy, list_layout);
	check(copy->items != list->items && intact(copy) && intact(list));
	zane_scope_drain(scope);
	check(zane_blocks == 0);

	/* The block must still move when it escapes its allocating scope. */
	scope = zane_scope_enter();
	int64_t inner = zane_scope_enter();
	list = make_list(inner);
	zane_list moved = *list;
	zane_promote((char *)&moved, list_layout, inner);
	check(moved.items != list->items && zane_region_at(moved.items)->depth == scope);
	zane_vacate((char *)list, list_layout);
	zane_scope_drain(inner);
	zane_list *kept = zane_slot(scope, sizeof *kept, 8, list_layout);
	*kept = moved;
	zane_arrive((char *)kept, list_layout);
	check(intact(kept));
	zane_scope_drain(scope);
	check(zane_blocks == 0);
}

/* An empty ownership layout still requires copying and overwriting payload bytes. */
static void exercise_boxes(void) {
	int64_t scope = zane_scope_enter();
	char **box = zane_slot(scope, sizeof *box, 8, box_layout);
	*box = zane_box(sizeof(int64_t), 8);
	*(int64_t *)*box = 7;
	char **copy = zane_slot(scope, sizeof *copy, 8, box_layout);
	*copy = *box;
	zane_copy((char *)copy, box_layout);
	check(*copy != *box && *(int64_t *)*copy == 7);

	/* An empty owned-block layout still describes payload bytes that an
	   overwrite must update, while preserving the old box's address. */
	char *kept = *box;
	char *incoming = zane_box(sizeof(int64_t), 8);
	*(int64_t *)incoming = 9;
	zane_overwrite((char *)box, (char *)&incoming, sizeof *box, box_layout);
	check(*box == kept && *(int64_t *)*box == 9 && *(int64_t *)*copy == 7);

	int64_t inner = zane_scope_enter();
	char *moved = zane_box(sizeof(int64_t), 8);
	*(int64_t *)moved = 11;
	zane_promote((char *)&moved, box_layout, inner);
	zane_scope_drain(inner);
	char **promoted = zane_slot(scope, sizeof *promoted, 8, box_layout);
	*promoted = moved;
	check(zane_region_at(moved)->depth == scope && *(int64_t *)moved == 11);
	zane_scope_drain(scope);
	check(zane_blocks == 0);
}

/* Repeat the checks for both ABI representations of an empty inner layout. */
void zane_main(void) {
#if defined(__linux__) && !defined(ZANE_TEST_ASAN)
	/* Two million 96-byte jobs grow the queue to 192 MiB. The lists and
	   their copies fit within 128 MiB. Keep an already stricter limit. */
	struct rlimit limit;
	if (getrlimit(RLIMIT_AS, &limit) != 0) zane_broken("cannot read the test memory budget");
	rlim_t budget = 128 * 1024 * 1024;
	if (limit.rlim_cur > budget) limit.rlim_cur = budget;
	if (setrlimit(RLIMIT_AS, &limit) != 0) zane_broken("cannot set the test memory budget");
#endif
	list_layout[5] = (int64_t)(intptr_t)scalar_layout;
	box_layout[5] = (int64_t)(intptr_t)scalar_layout;
	exercise_lists();
	exercise_boxes();
	list_layout[5] = 0;
	box_layout[5] = 0;
	exercise_lists();
	exercise_boxes();
}
