/* What the runtime's structs measure on the platform this is built for,
   each by the name runtime/zane_abi.h gives the number: the unit test
   compares it with the compiler's `Abi`, and dev/bin/windows-programs with
   the header itself, so a header that drifts from the structs fails on
   every platform the tests build for. ZANE_LINE, ZANE_STRETCH,
   ZANE_STRETCHED and ZANE_GUARD are not measured: nothing but the header
   defines them. */

#include "zane_internal.h"

static void show(const char *name, size_t value) { printf("%s %llu\n", name, (unsigned long long)value); }

#define SHOW(name, value) show(#name, value)

int main(void) {
#ifdef _WIN32
	/* The output is compared byte for byte, so a newline stays one byte. */
	_setmode(_fileno(stdout), _O_BINARY);
#endif
	zane_heap heap;
	SHOW(ZANE_CLASSES, sizeof heap.classes / sizeof heap.classes[0]);
	SHOW(ZANE_HEAP_BUMP, offsetof(zane_heap, bump));
	SHOW(ZANE_HEAP_END, offsetof(zane_heap, end));
	SHOW(ZANE_HEAP_LIVE, offsetof(zane_heap, live));
	SHOW(ZANE_MARK_HEAP, offsetof(zane_mark, heap));
	SHOW(ZANE_MARK_CONTEXT, offsetof(zane_mark, context));
	SHOW(ZANE_MARK_DEPTH, offsetof(zane_mark, depth));
	SHOW(ZANE_MARK_OUTER, offsetof(zane_mark, outer));
	SHOW(ZANE_MARK_SKIP, offsetof(zane_mark, skip));
	SHOW(ZANE_MARK_TASKS, offsetof(zane_mark, tasks));
	SHOW(ZANE_MARK_MAPPINGS, offsetof(zane_mark, mappings));
	SHOW(ZANE_MARK_STACKS, offsetof(zane_mark, stacks));
	SHOW(ZANE_MARK_SIZE, sizeof(zane_mark));
	SHOW(ZANE_CONTEXT_FRONTIER, offsetof(zane_context, frontier));
	SHOW(ZANE_CONTEXT_TOP, offsetof(zane_context, top));
	SHOW(ZANE_CONTEXT_LIMIT, offsetof(zane_context, limit));
	SHOW(ZANE_TASK_SIZE, sizeof(zane_task));
	SHOW(ZANE_HANDLE_LENGTH, offsetof(zane_text, length));
	SHOW(ZANE_HANDLE_ROOM, offsetof(zane_text, room));
	SHOW(ZANE_HANDLE_SIZE, sizeof(zane_text));
	return 0;
}
