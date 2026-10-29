#include "zane_internal.h"

/* ---------------------------------------------------------------------- */
/* Foreign handles (spec ffi.md §4, docs/design/ffi.md F12)               */
/* ---------------------------------------------------------------------- */

/* A handle is its C object's pointer and its stamp: the next of one
   process-wide count, taken as the handle is made, so a handle made from
   another has the larger stamp wherever each was made. 0 is no stamp. */
static int64_t zane_stamps;

int64_t zane_handle_made(void *object) {
	if (!object) return 0;
	return __atomic_add_fetch(&zane_stamps, 1, __ATOMIC_RELAXED);
}

/* A foreign verb that gives a handle and declares no abort found C
   returning no object (spec ffi.md §3.5). */
void zane_no_object(void) {
	zane_flush_output();
	fputs("a foreign function returned no object\n", stderr);
	exit(1);
}

static void zane_handle_run(const zane_handle_job *r) {
	void *object = r->object, *replacement = r->replacement;
	void *const args[2] = { &object, &replacement };
	r->thunk(args, NULL);
}

/* The releases being collected on this thread: a drain's or an
   overwrite's, which runs them once it has ended or replaced everything
   else (zane_handle_jobs_end). Outside one, a handle is released at once. */
static _Thread_local zane_handle_jobs *zane_collecting;

void zane_handle_jobs_begin(zane_handle_jobs *rs) {
	*rs = (zane_handle_jobs){ NULL, 0, 0, zane_collecting };
	zane_collecting = rs;
}

static void zane_handle_release(zane_handle_job r) {
	zane_handle_jobs *rs = zane_collecting;
	if (!rs) {
		zane_handle_run(&r);
		return;
	}
	if (rs->count == rs->room) {
		int64_t room = rs->room ? 2 * rs->room : 8;
		zane_handle_job *jobs = realloc(rs->jobs, (size_t)room * sizeof *jobs);
		if (!jobs) zane_broken("out of memory for the handles a drain releases");
		rs->jobs = jobs;
		rs->room = room;
	}
	rs->jobs[rs->count++] = r;
}

static int zane_younger_first(const void *a, const void *b) {
	int64_t x = ((const zane_handle_job *)a)->stamp, y = ((const zane_handle_job *)b)->stamp;
	return (x < y) - (x > y);
}

/* The releases collected run in the reverse of the order their handles
   were made, by descending stamp (spec ffi.md §4.2, §4.3), so one made
   from another goes first. */
void zane_handle_jobs_end(zane_handle_jobs *rs) {
	zane_collecting = rs->outer;
	qsort(rs->jobs, (size_t)rs->count, sizeof *rs->jobs, zane_younger_first);
	for (int64_t i = 0; i < rs->count; i++) zane_handle_run(&rs->jobs[i]);
	free(rs->jobs);
}

/* The releases collected are dropped unrun: they were of values a
   write-back replaced, whose handles the values written back still hold
   (snapshot.c). */
void zane_handle_jobs_drop(zane_handle_jobs *rs) {
	zane_collecting = rs->outer;
	free(rs->jobs);
}

/* A handle's end: its free thunk is called with its pointer, once, and the
   handle names nothing after. */
void zane_handle_end(char *at, zane_thunk free_thunk) {
	void *object;
	int64_t stamp;
	memcpy(&object, at, sizeof object);
	if (!object) return;
	memcpy(&stamp, at + sizeof object, sizeof stamp);
	memset(at, 0, sizeof object);
	zane_handle_release((zane_handle_job){ stamp, free_thunk, object, NULL });
}

/* A handle in a settled place replaced by the handle at `with` (spec
   ffi.md §4.3): the set thunk is called with the two pointers, which
   consumes the replacement, and the place keeps its pointer and stamp,
   written here over the replacement's before the overwrite copies the
   replacement's bytes into the place. A place that holds no object takes
   the replacement as it is. */
void zane_handle_set(char *at, char *with, zane_thunk set_thunk) {
	void *object, *replacement;
	int64_t stamp;
	memcpy(&object, at, sizeof object);
	if (!object) return;
	memcpy(&replacement, with, sizeof replacement);
	memcpy(&stamp, at + sizeof object, sizeof stamp);
	memcpy(with, at, sizeof object + sizeof stamp);
	zane_handle_release((zane_handle_job){ stamp, set_thunk, object, replacement });
}
