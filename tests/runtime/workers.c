/* The runtime's worker pools (concurrency.md §6), tested in C on their own:
   elements, steps, the funnel and its queue, timers, reads of a pool and
   its end, over hand-written thunks of the shape lowering makes
   (Lower_workers). A thunk here does its step's work itself instead of
   calling function values. Each check prints `yes` when it holds and `no`
   when it does not. */

#include "walks.h"

#include <time.h>
#ifdef _WIN32
#include <windows.h>
#endif

static int64_t test_now(void) {
#ifdef _WIN32
	LARGE_INTEGER count, rate;
	QueryPerformanceCounter(&count);
	QueryPerformanceFrequency(&rate);
	return (int64_t)((double)count.QuadPart * 1e9 / (double)rate.QuadPart);
#else
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (int64_t)t.tv_sec * 1000000000 + t.tv_nsec;
#endif
}

static void check(int ok) { puts(ok ? "yes" : "no"); }

/* The frames the runtime hands a step's thunk and a funnel's. */
typedef struct {
	void *step, *test, *publish;
	char *element, *state;
	uint8_t result;
} step_frame;

typedef struct {
	void *funnel;
	char *state, *event;
} funnel_frame;

enum { COUNTERS = 50, TO = 1000, PUBLISHERS = 20, EVENTS = 100 };

static int64_t total, overlapping;

/* A counter counts to TO, one step at a time; no two steps of one element
   ever run at once. */
typedef struct {
	int64_t n, busy;
} counter;

static void count_step(char *frame) {
	step_frame *f = (step_frame *)frame;
	counter *c = (counter *)f->element;
	if (__atomic_add_fetch(&c->busy, 1, __ATOMIC_ACQ_REL) != 1) __atomic_add_fetch(&overlapping, 1, __ATOMIC_RELAXED);
	c->n++;
	__atomic_add_fetch(&total, 1, __ATOMIC_RELAXED);
	__atomic_sub_fetch(&c->busy, 1, __ATOMIC_ACQ_REL);
	f->result = c->n < TO;
}

/* A publisher publishes its id and a sequence number, 1 to EVENTS; the
   funnel adds the numbers to the state and checks each publisher's arrive
   in order. */
typedef struct {
	int64_t id, seq;
} publisher;

typedef struct {
	int64_t sum, applied;
} tally;

static int64_t last_seen[PUBLISHERS], out_of_order;

static void publish_step(char *frame) {
	step_frame *f = (step_frame *)frame;
	publisher *p = (publisher *)f->element;
	p->seq++;
	int64_t event[2] = { p->id, p->seq };
	zane_workers_publish((char *)event, sizeof event, NULL);
	f->result = p->seq < EVENTS;
}

static void add_event(char *frame) {
	funnel_frame *f = (funnel_frame *)frame;
	tally *t = (tally *)f->state;
	int64_t *event = (int64_t *)f->event;
	if (event[1] != last_seen[event[0]] + 1) out_of_order++;
	last_seen[event[0]] = event[1];
	t->sum += event[1];
	t->applied++;
}

/* A string element grows by one byte each step, as `this.s = this.s +
   "x"` does: the joined string is made in the step's scope and arrives in
   the element's place. */
static const zane_text one_x = { "x", 1, 0 };

static void grow_step(char *frame) {
	step_frame *f = (step_frame *)frame;
	zane_text *s = (zane_text *)f->element;
	zane_text grown;
	zane_text_join(&grown, s, &one_x);
	zane_overwrite((char *)s, (char *)&grown, sizeof grown, &text_type);
	f->result = s->length < 64;
}

/* A worker on a timer counts its calls and stops after ten. */
typedef struct {
	int64_t calls, first, last;
} ticker;

static void tick_step(char *frame) {
	step_frame *f = (step_frame *)frame;
	ticker *t = (ticker *)f->element;
	int64_t now = test_now();
	if (!t->calls) t->first = now;
	t->last = now;
	t->calls++;
	f->result = t->calls < 10;
}

/* A worker started with an empty list of sources waits for the state
   alone: it is called again only when the funnel has changed it, and
   stops once five events are applied. */
typedef struct {
	int64_t calls;
} watcher;

static void watch_step(char *frame) {
	step_frame *f = (step_frame *)frame;
	watcher *w = (watcher *)f->element;
	w->calls++;
	f->result = ((tally *)f->state)->applied < 5;
}

static void five_step(char *frame) {
	step_frame *f = (step_frame *)frame;
	publisher *p = (publisher *)f->element;
	p->seq++;
	int64_t event[2] = { 0, p->seq };
	zane_workers_publish((char *)event, sizeof event, NULL);
	f->result = p->seq < 5;
}

static void end_pool(char *handle) {
	void *object;
	memcpy(&object, handle, sizeof object);
	void *const args[2] = { &object, NULL };
	zane_workers_free(args, NULL);
}

static void stateless(void) {
	char handle[16];
	total = overlapping = 0;
	zane_workers_new(handle, NULL, 0, NULL, NULL, NULL, 0, NULL);
	for (int i = 0; i < COUNTERS; i++) {
		counter c = { 0, 0 };
		zane_workers_start(handle, (char *)&c, sizeof c, NULL, count_step, NULL, NULL, NULL, NULL);
	}
	end_pool(handle);
	check(total == (int64_t)COUNTERS * TO && overlapping == 0);
}

static void stateful(void) {
	char handle[16];
	tally start = { 0, 0 };
	memset(last_seen, 0, sizeof last_seen);
	out_of_order = 0;
	zane_workers_new(handle, (char *)&start, sizeof start, NULL, NULL, add_event, 2 * sizeof(int64_t), NULL);
	for (int64_t i = 0; i < PUBLISHERS; i++) {
		publisher p = { i, 0 };
		zane_workers_start(handle, (char *)&p, sizeof p, NULL, publish_step, NULL, NULL, NULL, NULL);
	}
	/* `start` returns at once, and the state can be read while the workers
	   run. */
	tally now;
	zane_workers_state(handle, (char *)&now);
	int partial = now.sum >= 0 && now.sum <= (int64_t)PUBLISHERS * EVENTS * (EVENTS + 1) / 2;
	end_pool(handle);
	check(partial);
	check(out_of_order == 0);
	for (int64_t i = 0; i < PUBLISHERS; i++)
		if (last_seen[i] != EVENTS) out_of_order++;
	check(out_of_order == 0);
}

static void read_state(void) {
	char handle[16];
	tally start = { 7, 0 };
	zane_workers_new(handle, (char *)&start, sizeof start, NULL, NULL, add_event, 2 * sizeof(int64_t), NULL);
	publisher p = { 0, 0 };
	memset(last_seen, 0, sizeof last_seen);
	zane_workers_start(handle, (char *)&p, sizeof p, NULL, five_step, NULL, NULL, NULL, NULL);
	tally after;
	/* Wait for the funnel without ending the pool. */
	for (int64_t until = test_now() + 2000000000; test_now() < until;) {
		zane_workers_state(handle, (char *)&after);
		if (after.applied == 5) break;
		sched_yield();
	}
	check(after.sum == 7 + 15 && after.applied == 5);
	end_pool(handle);
}

static void owning_elements(void) {
	zane_mark *scope = zane_scope_enter(0);
	char handle[16];
	zane_workers_new(handle, NULL, 0, NULL, NULL, NULL, 0, NULL);
	for (int i = 0; i < 8; i++) {
		zane_text *s = test_slot(scope, sizeof *s, 8, NULL);
		zane_text_join(s, &one_x, &one_x);
		/* The element moves in: the slot names nothing after. */
		zane_workers_start(handle, (char *)s, sizeof *s, &text_type, grow_step, NULL, NULL, NULL, NULL);
		memset(s, 0, sizeof *s);
	}
	zane_list *copies = test_slot(scope, sizeof *copies, 8, &texts_type);
	zane_workers_elements(handle, copies, sizeof(zane_text), &text_type);
	int whole = ZL_COUNT(copies) <= 8;
	for (int64_t i = 0; i < ZL_COUNT(copies); i++) {
		zane_text *t = (zane_text *)ZL_ITEMS(copies) + i;
		for (int64_t k = 0; k < t->length; k++) whole &= t->bytes[k] == 'x';
	}
	end_pool(handle);
	check(whole);
	zane_scope_drain(scope);
}

static void timers(void) {
	char handle[16];
	zane_workers_new(handle, NULL, 0, NULL, NULL, NULL, 0, NULL);
	int64_t before = test_now();
	zane_list every;
	zane_list_new(&every);
	*(int64_t *)zane_list_push(&every, 8) = 5000000;
	ticker t = { 0, 0, 0 };
	zane_workers_start(handle, (char *)&t, sizeof t, NULL, tick_step, NULL, NULL, NULL, &every);
	zane_list always;
	zane_list_new(&always);
	*(int64_t *)zane_list_push(&always, 8) = 0;
	zane_workers_start(handle, (char *)&t, sizeof t, NULL, tick_step, NULL, NULL, NULL, &always);
	end_pool(handle);
	int64_t took = test_now() - before;
	/* Ten calls 5 ms apart, the first at once: 45 ms at least. */
	check(took >= 45000000);
}

static void state_wakes(void) {
	char handle[16];
	tally start = { 0, 0 };
	zane_workers_new(handle, (char *)&start, sizeof start, NULL, NULL, add_event, 2 * sizeof(int64_t), NULL);
	memset(last_seen, 0, sizeof last_seen);
	zane_list none;
	zane_list_new(&none);
	watcher w = { 0 };
	zane_workers_start(handle, (char *)&w, sizeof w, NULL, watch_step, NULL, NULL, NULL, &none);
	publisher p = { 0, 0 };
	zane_workers_start(handle, (char *)&p, sizeof p, NULL, five_step, NULL, NULL, NULL, NULL);
	/* The pool ends only if the watcher is woken by the funnel's writes:
	   it waits on no timer. */
	end_pool(handle);
	check(1);
}

void zane_main(void) {
	zane_checking = 1;
	stateless();
	stateful();
	read_state();
	owning_elements();
	timers();
	state_wakes();
	/* With one thread, an ending pool runs its own work. */
	check(zane_set_threads(1) == 1);
	stateless();
	stateful();
	zane_set_threads_auto();
}
