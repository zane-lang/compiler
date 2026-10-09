/* Elements that own no blocks must not hand on a walk per scalar (#191):
   their list's type has walks for its own block alone. The memory budget
   catches that regression without a timing threshold. The list's bytes
   stay intact through copying and promotion, and its backing block is
   returned. */

#include "walks.h"

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

/* Hold the list in the requested scope so its backing blocks drain with it. */
static zane_list *make_list(zane_mark *scope) {
	zane_list *list = test_slot(scope, sizeof *list, 8, &ints_type);
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
	zane_mark *scope = zane_scope_enter(0);
	zane_list *list = make_list(scope);
	check(intact(list));
	zane_scope_drain(scope);
	check(zane_blocks() == 0);

	/* A copy owns a separate block, including when its elements own none. */
	scope = zane_scope_enter(0);
	list = make_list(scope);
	zane_list *copy = test_slot(scope, sizeof *copy, 8, &ints_type);
	*copy = *list;
	zane_copy((char *)copy, &ints_type);
	check(copy->items != list->items && intact(copy) && intact(list));
	zane_scope_drain(scope);
	check(zane_blocks() == 0);

	/* The block must still move when it escapes its allocating scope. */
	scope = zane_scope_enter(0);
	zane_mark *inner = zane_scope_enter(0);
	list = make_list(inner);
	zane_list moved = *list;
	zane_promote((char *)&moved, &ints_type, inner);
	check(moved.items != list->items && zane_region_at(moved.items) == scope);
	*list = (zane_list){ NULL, 0, 0 };
	zane_scope_drain(inner);
	zane_list *kept = test_slot(scope, sizeof *kept, 8, &ints_type);
	*kept = moved;
	zane_arrive((char *)kept, &ints_type);
	check(intact(kept));
	zane_scope_drain(scope);
	check(zane_blocks() == 0);
}

/* A payload that owns no blocks still has its bytes copied and overwritten. */
static void exercise_boxes(void) {
	zane_mark *scope = zane_scope_enter(0);
	char **box = test_slot(scope, sizeof *box, 8, &boxed_int_type);
	*box = zane_box(sizeof(int64_t), 8);
	*(int64_t *)*box = 7;
	char **copy = test_slot(scope, sizeof *copy, 8, &boxed_int_type);
	*copy = *box;
	zane_copy((char *)copy, &boxed_int_type);
	check(*copy != *box && *(int64_t *)*copy == 7);

	/* An overwrite still updates the payload's bytes, while preserving the
	   old box's address. */
	char *kept = *box;
	char *incoming = zane_box(sizeof(int64_t), 8);
	*(int64_t *)incoming = 9;
	zane_overwrite((char *)box, (char *)&incoming, sizeof *box, &boxed_int_type);
	check(*box == kept && *(int64_t *)*box == 9 && *(int64_t *)*copy == 7);

	zane_mark *inner = zane_scope_enter(0);
	char *moved = zane_box(sizeof(int64_t), 8);
	*(int64_t *)moved = 11;
	zane_promote((char *)&moved, &boxed_int_type, inner);
	zane_scope_drain(inner);
	char **promoted = test_slot(scope, sizeof *promoted, 8, &boxed_int_type);
	*promoted = moved;
	check(zane_region_at(moved) == scope && *(int64_t *)moved == 11);
	zane_scope_drain(scope);
	check(zane_blocks() == 0);
}

void zane_main(void) {
#if defined(__linux__) && !defined(ZANE_TEST_ASAN)
	/* The lists and their copies fit within 128 MiB, and so does nothing
	   that also walks each of their two million elements. The limit counts
	   addresses, so it is 128 MiB beyond the range the main context
	   reserved for its frames, whose untouched pages take no memory. Keep
	   an already stricter limit. */
	struct rlimit limit;
	if (getrlimit(RLIMIT_AS, &limit) != 0) zane_broken("cannot read the test memory budget");
	rlim_t budget = (rlim_t)128 * 1024 * 1024 + (rlim_t)(zane_self->limit + ZANE_GUARD - zane_self->base);
	if (limit.rlim_cur > budget) limit.rlim_cur = budget;
	if (setrlimit(RLIMIT_AS, &limit) != 0) zane_broken("cannot set the test memory budget");
#endif
	exercise_lists();
	exercise_boxes();
}
