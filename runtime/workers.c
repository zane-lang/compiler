/* Copyright (C) 2026 The Zane Authors

   This file is part of the Zane runtime library. It is governed by the GNU
   General Public License, version 3, along with the Zane Compiler Runtime
   Library Exception; the compiler's LICENSE, at the root of its source and
   in share/ of its releases, holds both. */

#include "zane_internal.h"

#include <errno.h>
#include <time.h>
#ifdef _WIN32
#include <windows.h>
#endif

/* ---------------------------------------------------------------------- */
/* Worker pools (concurrency.md §6, docs/design/lowering.md, step 13)      */
/* ---------------------------------------------------------------------- */

/* A pool is a `zane_workers`, named by a 16-byte handle as a foreign
   handle is: its address and a stamp. The scope that holds the handle ends
   it when it drains, through `zane_workers_free`, which waits for the
   pool's workers and its funnel first (§6.7).

   Each element lives in a region of its own (a `zane_member`'s `mark`),
   like the region a spawned call's subject lives in: no scope, so it outlives
   none, and written only by the step running on it. The shared state lives
   in a second such region, written only by the funnel, and the events
   waiting for the funnel in a third. Each of the three regions is touched
   by one thread at a time, under the lock that guards it, and takes its
   chunks from the context of the thread touching it, which the region's
   record names while it does (`zane_claim`).

   The thread pool runs the pools' work as jobs: a step to call on an
   element, or a funnel to drain. A pool thread takes a spawned call first,
   then a job (spawn.c). Jobs wait in one ready queue, and a worker started
   with event sources waits between calls in a heap ordered by its next
   deadline, holding no thread, until a timer is due or the funnel changes
   the state. Both are guarded by `zane_ready`. A pool's lock is taken
   before `zane_ready` whenever both are held. */

typedef struct zane_workers zane_workers;
typedef struct zane_member zane_member;

enum { ZANE_STEP_JOB, ZANE_FUNNEL_JOB };

typedef struct zane_pool_job {
	struct zane_pool_job *next;
	zane_workers *pool;
	int kind;
} zane_pool_job;

/* What a step's thunk reads, and where it stores the step's result: the
   step, its result's conversion to a Bool, and the publish function, each
   a function value; the element's address; and the state snapshot's
   address, null for a pool with no state. Lowering lays out the same
   struct (Lower_workers). */
typedef struct {
	void *step, *test, *publish;
	char *element, *state;
	uint8_t result;
} zane_step_frame;

/* What a funnel's thunk reads: the funnel, the state's address and the
   event's. */
typedef struct {
	void *funnel;
	char *state, *event;
} zane_funnel_frame;

typedef struct zane_event {
	struct zane_event *next;
	int64_t size;
} zane_event;

struct zane_member {
	zane_pool_job job;
	zane_mark mark;
	zane_member *before, *after;
	char *value;
	int64_t size;
	const zane_type *type;
	void (*thunk)(char *frame);
	void *step, *test, *publish;
	/* Its timers: each one's interval and next deadline, on the monotonic
	   clock. `sources` says whether it was started with event sources at
	   all, since a worker started with an empty list waits for the state
	   alone. */
	int64_t *intervals, *deadlines, timers;
	int sources;
	/* The state's version its step last read. */
	uint64_t seen;
	/* Its place in the heap of waiting workers, or -1, and the next
	   waiting worker of its pool; both under `zane_ready`. */
	int64_t heap_at;
	zane_member *sleeping_next, *sleeping_before;
	/* Held while its step runs, so a read of the pool's elements takes it
	   whole (§6.6). */
	pthread_mutex_t lock;
};

struct zane_workers {
	zane_pool_job funnel_job;
	pthread_mutex_t lock;
	pthread_cond_t done;
	/* The state, in a region of its own, which the funnel writes under
	   `state_lock`; every copy of it is taken under the same lock. Its
	   version counts the events applied. */
	pthread_mutex_t state_lock;
	zane_mark state_mark;
	char *state;
	int64_t state_size;
	const zane_type *state_type;
	uint64_t version;
	void (*funnel_thunk)(char *frame);
	void *funnel;
	/* The events published and not yet applied, oldest first, with their
	   blocks in a region of their own, and whether the funnel's job is
	   queued or running; all under `queue_lock`. A step publishes while it
	   holds its element's lock, so the queue has a lock of its own. */
	pthread_mutex_t queue_lock;
	zane_mark queue_mark;
	zane_event *first, *last;
	int64_t event_size;
	const zane_type *event_type;
	/* The event type's identity: a hash of its symbol, the same in every
	   object, where the walk tables are each object's own. */
	int64_t event_id;
	int funnel_busy;
	/* The elements, in the order they started, and how many, under
	   `lock`. */
	zane_member *members, *last_member;
	int64_t live;
	/* The workers waiting on their sources, under `zane_ready`. */
	zane_member *sleeping;
};

static pthread_mutex_t zane_ready = PTHREAD_MUTEX_INITIALIZER;
static zane_pool_job *zane_ready_first, *zane_ready_last;
/* How many jobs are queued, and how many workers wait in the heap; read
   without the lock by a thread deciding whether to look. */
int64_t zane_jobs, zane_sleepers;
static zane_member **zane_timers;
static int64_t zane_timer_count, zane_timer_room;

/* The monotonic clock, in nanoseconds. */
static int64_t zane_now(void) {
#ifdef _WIN32
	LARGE_INTEGER count, rate;
	QueryPerformanceFrequency(&rate);
	QueryPerformanceCounter(&count);
	return (int64_t)(count.QuadPart / rate.QuadPart) * 1000000000 +
	       (int64_t)(count.QuadPart % rate.QuadPart) * 1000000000 / rate.QuadPart;
#else
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (int64_t)t.tv_sec * 1000000000 + t.tv_nsec;
#endif
}

/* The deadline `ticks` intervals after `from`. A deadline past the largest
   time an int64_t holds becomes that largest time, which no clock reaches,
   so a timer with an interval that large is never ready. */
static int64_t zane_later(int64_t from, int64_t ticks, int64_t interval) {
	int64_t span, at;
	if (__builtin_mul_overflow(ticks, interval, &span) || __builtin_add_overflow(from, span, &at)) return INT64_MAX;
	return at;
}

/* `@controlflow$register` on a timer (control-flow.md §4.1): its first
   deadline, an interval after the call begins, and 0 for an interval below
   1, which is always ready. */
int64_t zane_tick_start(int64_t interval) { return interval < 1 ? 0 : zane_later(zane_now(), 1, interval); }

/* The wait between two steps of a `register` on a timer: until `deadline`,
   with a stand-in thread when this is a pool thread (zane_block_begin), so
   the wait holds back only the `register`'s caller (concurrency.md §3.4). The
   next deadline is the first after the wait, so missed ticks merge as a
   pool's do (zane_consume). An interval below 1 waits not at all. */
int64_t zane_tick(int64_t interval, int64_t deadline) {
	if (interval < 1) return deadline;
	int64_t now = zane_now();
	if (deadline > now) {
		int began = zane_block_begin();
		while (deadline > now) {
			zane_sleep(deadline - now);
			now = zane_now();
		}
		zane_block_end(began);
	}
	return zane_later(deadline, (now - deadline) / interval + 1, interval);
}

/* The wall-clock time `nanoseconds` from now, for a timed wait on a
   condition, which waits on the wall clock. */
void zane_wait_until(pthread_cond_t *cond, pthread_mutex_t *lock, int64_t deadline) {
	int64_t left = deadline - zane_now();
	if (left <= 0) return;
	struct timespec at;
	clock_gettime(CLOCK_REALTIME, &at);
	int64_t ns = (int64_t)at.tv_nsec + left % 1000000000;
	at.tv_sec += (time_t)(left / 1000000000 + ns / 1000000000);
	at.tv_nsec = (long)(ns % 1000000000);
	pthread_cond_timedwait(cond, lock, &at);
}

/* A region of a pool's, about to be written by this thread: it takes its
   chunks from, and gives them back to, this thread's context. */
static void zane_claim(zane_mark *m) { m->context = zane_self; }

static void zane_region_init(zane_mark *m) {
	memset(m, 0, sizeof *m);
	m->context = zane_self;
	m->depth = ZANE_ISLAND_DEPTH;
}

/* The value at `at`, `size` bytes, is copied whole into a block of region
   `m`, which is claimed: each block the value names gets a copy of its own
   there. */
static char *zane_copy_into(zane_mark *m, const char *from, int64_t size, const zane_type *type) {
	zane_claim(m);
	char *at = zane_alloc_held(m, size < 8 ? 8 : size, 16);
	m->heap.live--;
	memcpy(at, from, (size_t)size);
	if (type) {
		zane_work w;
		zane_work_start(&w);
		type->copy(at, (char *)m, 0, &w, 0);
		zane_work_run(&w);
	}
	return at;
}

/* A region of a pool's is done with: what its value owns is ended, and
   its chunks go back. */
static void zane_region_end(zane_mark *m, char *value, const zane_type *type) {
	zane_claim(m);
	if (value && type) {
		zane_handle_jobs handles;
		zane_handle_jobs_begin(&handles);
		zane_end(value, type);
		zane_handle_jobs_end(&handles);
	}
	if (zane_checking && m->heap.live != 0) zane_broken("a dynamic block outlived its owner");
	zane_unmap(m);
}

/* ---- The heap of waiting workers, by next deadline --------------------- */

static int64_t zane_deadline(const zane_member *m) {
	int64_t d = INT64_MAX;
	for (int64_t i = 0; i < m->timers; i++)
		if (m->deadlines[i] < d) d = m->deadlines[i];
	return d;
}

static void zane_timer_set(int64_t i, zane_member *m) {
	zane_timers[i] = m;
	m->heap_at = i;
}

static void zane_timer_up(int64_t i) {
	zane_member *m = zane_timers[i];
	int64_t d = zane_deadline(m);
	while (i > 0) {
		int64_t up = (i - 1) / 2;
		if (zane_deadline(zane_timers[up]) <= d) break;
		zane_timer_set(i, zane_timers[up]);
		i = up;
	}
	zane_timer_set(i, m);
}

static void zane_timer_down(int64_t i) {
	zane_member *m = zane_timers[i];
	int64_t d = zane_deadline(m);
	for (;;) {
		int64_t l = 2 * i + 1, r = l + 1, least = i, ld = d;
		if (l < zane_timer_count && zane_deadline(zane_timers[l]) < ld) {
			least = l;
			ld = zane_deadline(zane_timers[l]);
		}
		if (r < zane_timer_count && zane_deadline(zane_timers[r]) < ld) least = r;
		if (least == i) break;
		zane_timer_set(i, zane_timers[least]);
		i = least;
	}
	zane_timer_set(i, m);
}

static void zane_timer_push(zane_member *m) {
	if (zane_timer_count == zane_timer_room) {
		int64_t room = zane_timer_room ? 2 * zane_timer_room : 64;
		zane_member **h = realloc(zane_timers, (size_t)room * sizeof *h);
		if (!h) zane_broken("out of memory for the waiting workers");
		zane_timers = h;
		zane_timer_room = room;
	}
	zane_timer_set(zane_timer_count++, m);
	zane_timer_up(m->heap_at);
}

static void zane_timer_remove(zane_member *m) {
	int64_t i = m->heap_at;
	m->heap_at = -1;
	zane_timer_count--;
	if (i == zane_timer_count) return;
	zane_timer_set(i, zane_timers[zane_timer_count]);
	zane_timer_down(i);
	zane_timer_up(zane_timers[i]->heap_at);
}

/* ---- The ready queue ---------------------------------------------------- */

/* A job queued; `zane_ready` is held. */
static void zane_queue(zane_pool_job *j) {
	j->next = NULL;
	if (zane_ready_last) zane_ready_last->next = j;
	else zane_ready_first = j;
	zane_ready_last = j;
	__atomic_add_fetch(&zane_jobs, 1, __ATOMIC_RELEASE);
}

/* A waiting worker woken; `zane_ready` is held. */
static void zane_wake(zane_member *m) {
	zane_workers *p = m->job.pool;
	if (m->heap_at >= 0) zane_timer_remove(m);
	if (m->sleeping_before) m->sleeping_before->sleeping_next = m->sleeping_next;
	else p->sleeping = m->sleeping_next;
	if (m->sleeping_next) m->sleeping_next->sleeping_before = m->sleeping_before;
	m->sleeping_next = m->sleeping_before = NULL;
	__atomic_sub_fetch(&zane_sleepers, 1, __ATOMIC_RELAXED);
	zane_queue(&m->job);
}

/* The workers whose next deadline has passed, woken; `zane_ready` is
   held. */
static void zane_wake_due(void) {
	if (!zane_timer_count) return;
	int64_t now = zane_now();
	while (zane_timer_count && zane_deadline(zane_timers[0]) <= now) zane_wake(zane_timers[0]);
}

/* The next deadline of any waiting worker, or -1 when none waits. */
int64_t zane_workers_next_deadline(void) {
	if (!__atomic_load_n(&zane_sleepers, __ATOMIC_ACQUIRE)) return -1;
	pthread_mutex_lock(&zane_ready);
	int64_t d = zane_timer_count ? zane_deadline(zane_timers[0]) : -1;
	pthread_mutex_unlock(&zane_ready);
	return d;
}

/* The oldest job queued, of pool `only` when it is set; `zane_ready` is
   held. */
static zane_pool_job *zane_take(zane_workers *only) {
	zane_pool_job *prev = NULL;
	for (zane_pool_job *j = zane_ready_first; j; prev = j, j = j->next) {
		if (only && j->pool != only) continue;
		if (prev) prev->next = j->next;
		else zane_ready_first = j->next;
		if (zane_ready_last == j) zane_ready_last = prev;
		j->next = NULL;
		__atomic_sub_fetch(&zane_jobs, 1, __ATOMIC_RELAXED);
		return j;
	}
	return NULL;
}

/* ---- Running a job ----------------------------------------------------- */

/* Whether pool `p` has nothing left to do: no element, and no event
   waiting or being applied; its lock is held. The last of these to clear
   is cleared under that lock, by a thread that touches the pool no more
   after it lets the lock go, so the thread that ends the pool may free it
   as soon as it sees it finished. The locks are taken in the order the
   pool's, an element's, the queue's. */
static int zane_pool_finished(zane_workers *p) {
	/* The funnel stays busy until it finds the queue empty, and only a
	   running step or the funnel publishes, so an idle funnel with no
	   element left shows an empty queue. */
	return p->live == 0 && !__atomic_load_n(&p->funnel_busy, __ATOMIC_ACQUIRE);
}

/* A step's or a funnel's call runs in a context of its own, as a spawned
   call does (§6.4), which names the pool its work belongs to so that a
   publish from it, or from a call it spawns, reaches that pool. */
static zane_context *zane_job_enter(zane_workers *p) {
	zane_context *c = zane_context_new();
	c->workers = p;
	zane_self = c;
	zane_scope_enter(0);
	return c;
}

static void zane_job_leave(zane_context *c, zane_context *outer) {
	zane_self = outer;
	zane_context *joining = zane_joining;
	zane_joining = c;
	c->workers = NULL;
	zane_context_release(c);
	zane_joining = joining;
	zane_reopen();
}

/* A deadline for each timer, the first interval from now; a timer whose
   interval is below 1 is always ready, so its deadline is now. */
static void zane_consume(zane_member *m, int64_t now) {
	for (int64_t i = 0; i < m->timers; i++) {
		int64_t every = m->intervals[i], d = m->deadlines[i];
		if (d > now) continue;
		if (every < 1) {
			m->deadlines[i] = now;
			continue;
		}
		/* Missed ticks merge: the next deadline is the first after now. */
		m->deadlines[i] = zane_later(d, (now - d) / every + 1, every);
	}
}

static void zane_member_end(zane_member *m) {
	zane_region_end(&m->mark, m->value, m->type);
	pthread_mutex_destroy(&m->lock);
	free(m->intervals);
	free(m);
}

static void zane_run_step(zane_member *m) {
	zane_workers *p = m->job.pool;
	zane_context *outer = zane_self;
	zane_context *c = zane_job_enter(p);
	pthread_mutex_lock(&m->lock);
	zane_claim(&m->mark);
	zane_consume(m, zane_now());
	zane_step_frame frame = { m->step, m->test, m->publish, m->value, NULL, 0 };
	char *snapshot = NULL;
	if (p->state) {
		/* A state of no bytes, a `Unit`, has nothing to read, but the
		   version the call saw is still recorded. */
		int reads = p->state_size || p->state_type;
		if (reads) {
			snapshot = malloc((size_t)(p->state_size < 8 ? 8 : p->state_size));
			if (!snapshot) zane_broken("out of memory for a state snapshot");
		}
		pthread_mutex_lock(&p->state_lock);
		if (reads) {
			memcpy(snapshot, p->state, (size_t)p->state_size);
			zane_copy(snapshot, p->state_type);
		}
		m->seen = __atomic_load_n(&p->version, __ATOMIC_ACQUIRE);
		pthread_mutex_unlock(&p->state_lock);
		frame.state = snapshot;
	}
	m->thunk((char *)&frame);
	if (snapshot) {
		zane_end(snapshot, p->state_type);
		free(snapshot);
	}
	pthread_mutex_unlock(&m->lock);
	if (!frame.result) {
		/* The element leaves the list first, so no read of the elements
		   reaches it once it is ended; the pool counts it out last, so
		   the pool is not seen finished before its element is gone. */
		pthread_mutex_lock(&p->lock);
		if (m->before) m->before->after = m->after;
		else p->members = m->after;
		if (m->after) m->after->before = m->before;
		else p->last_member = m->before;
		pthread_mutex_unlock(&p->lock);
		zane_member_end(m);
		zane_job_leave(c, outer);
		pthread_mutex_lock(&p->lock);
		p->live--;
		pthread_cond_broadcast(&p->done);
		pthread_mutex_unlock(&p->lock);
		return;
	}
	zane_job_leave(c, outer);
	pthread_mutex_lock(&zane_ready);
	if (!m->sources || __atomic_load_n(&p->version, __ATOMIC_ACQUIRE) != m->seen) {
		zane_queue(&m->job);
	} else {
		/* A tick that came due during the step queues the next call,
		   which consumes it. */
		int64_t now = zane_now();
		int ready = 0;
		for (int64_t i = 0; i < m->timers; i++)
			if (m->deadlines[i] <= now) ready = 1;
		if (ready) {
			zane_queue(&m->job);
		} else {
			m->sleeping_before = NULL;
			m->sleeping_next = p->sleeping;
			if (p->sleeping) p->sleeping->sleeping_before = m;
			p->sleeping = m;
			__atomic_add_fetch(&zane_sleepers, 1, __ATOMIC_RELEASE);
			if (m->timers) zane_timer_push(m);
		}
	}
	pthread_mutex_unlock(&zane_ready);
	zane_pool_wake();
}

static void zane_run_funnel(zane_workers *p) {
	zane_context *outer = zane_self;
	zane_context *c = zane_job_enter(p);
	for (;;) {
		pthread_mutex_lock(&p->lock);
		pthread_mutex_lock(&p->queue_lock);
		zane_event *e = p->first;
		if (!e) {
			__atomic_store_n(&p->funnel_busy, 0, __ATOMIC_RELEASE);
			pthread_mutex_unlock(&p->queue_lock);
			pthread_cond_broadcast(&p->done);
			pthread_mutex_unlock(&p->lock);
			break;
		}
		pthread_mutex_unlock(&p->queue_lock);
		pthread_mutex_unlock(&p->lock);
		pthread_mutex_lock(&p->state_lock);
		zane_claim(&p->state_mark);
		zane_funnel_frame frame = { p->funnel, p->state, (char *)(e + 1) };
		p->funnel_thunk((char *)&frame);
		__atomic_add_fetch(&p->version, 1, __ATOMIC_RELEASE);
		pthread_mutex_unlock(&p->state_lock);
		/* The event leaves the queue only once it is applied, so the pool
		   is not seen finished while it is being applied. */
		pthread_mutex_lock(&p->queue_lock);
		p->first = e->next;
		if (!e->next) p->last = NULL;
		zane_claim(&p->queue_mark);
		zane_end((char *)(e + 1), p->event_type);
		pthread_mutex_unlock(&p->queue_lock);
		free(e);
		pthread_mutex_lock(&zane_ready);
		int woke = p->sleeping != NULL;
		while (p->sleeping) zane_wake(p->sleeping);
		pthread_mutex_unlock(&zane_ready);
		if (woke) zane_pool_wake();
	}
	zane_job_leave(c, outer);
}

/* A job run on this thread. */
static void zane_run_job(zane_pool_job *j) {
	zane_workers *p = j->pool;
	if (j->kind == ZANE_FUNNEL_JOB) {
		zane_run_funnel(p);
		return;
	}
	zane_run_step((zane_member *)j);
}

/* One job, of pool `only` when it is set, taken and run here. Whether
   there was one. */
int zane_workers_run_one(zane_workers *only) {
	if (!__atomic_load_n(&zane_jobs, __ATOMIC_ACQUIRE) && !__atomic_load_n(&zane_sleepers, __ATOMIC_ACQUIRE))
		return 0;
	pthread_mutex_lock(&zane_ready);
	zane_wake_due();
	zane_pool_job *j = zane_take(only);
	pthread_mutex_unlock(&zane_ready);
	if (!j) return 0;
	zane_run_job(j);
	return 1;
}

/* ---- What emitted code calls ------------------------------------------- */

/* A new pool (§6.1), whose handle is its address and a stamp that the
   caller takes. A pool `stateful` is given the state, which it copies into
   its own region, the funnel, and the funnel's thunk; a pool without reads
   none of them. Events are `event_size` bytes of `event_type`, whose
   identity is `event_id`. */
void *zane_workers_new(int64_t stateful, char *state, int64_t state_size, const zane_type *state_type, void *funnel,
                       void (*funnel_thunk)(char *), int64_t event_size, const zane_type *event_type,
                       int64_t event_id) {
	zane_workers *p = calloc(1, sizeof *p);
	if (!p) zane_broken("out of memory for a worker pool");
	p->funnel_job.pool = p;
	p->funnel_job.kind = ZANE_FUNNEL_JOB;
	pthread_mutex_init(&p->lock, NULL);
	pthread_mutex_init(&p->state_lock, NULL);
	pthread_mutex_init(&p->queue_lock, NULL);
	pthread_cond_init(&p->done, NULL);
	zane_region_init(&p->state_mark);
	zane_region_init(&p->queue_mark);
	if (stateful) {
		p->state = zane_copy_into(&p->state_mark, state, state_size, state_type);
		p->state_size = state_size;
		p->state_type = state_type;
	}
	p->funnel = funnel;
	/* A pool without state has no funnel, whatever it was passed. */
	p->funnel_thunk = stateful ? funnel_thunk : NULL;
	p->event_size = event_size;
	p->event_type = event_type;
	p->event_id = event_id;
	return p;
}

static zane_workers *zane_workers_at(const char *handle) {
	zane_workers *p;
	memcpy(&p, handle, sizeof p);
	if (!p) zane_broken("a worker pool used after it ended");
	return p;
}

/* A worker added (§6.2): the element at `element`, `size` bytes of `type`,
   which the call owns and moves into a region of its own, and the step
   that runs on it through `thunk`. With `has_sources`, `sources` is the
   list of event sources, each an interval of nanoseconds; without, it is
   not read. Its first call comes right after this one returns. */
void zane_workers_start(char *handle, char *element, int64_t size, const zane_type *type, void (*thunk)(char *),
                        void *step, void *test, void *publish, int64_t has_sources, const zane_list *sources) {
	zane_workers *p = zane_workers_at(handle);
	zane_member *m = calloc(1, sizeof *m);
	if (!m) zane_broken("out of memory for a worker");
	m->job.pool = p;
	m->job.kind = ZANE_STEP_JOB;
	m->heap_at = -1;
	pthread_mutex_init(&m->lock, NULL);
	zane_region_init(&m->mark);
	m->value = zane_alloc_held(&m->mark, size < 8 ? 8 : size, 16);
	m->mark.heap.live--;
	memcpy(m->value, element, (size_t)size);
	zane_move(m->value, type, &m->mark, 0);
	m->size = size;
	m->type = type;
	m->thunk = thunk;
	m->step = step;
	m->test = test;
	m->publish = publish;
	if (has_sources) {
		m->sources = 1;
		int64_t n = ZL_COUNT(sources);
		if (n) {
			m->intervals = malloc((size_t)(2 * n) * sizeof *m->intervals);
			if (!m->intervals) zane_broken("out of memory for a worker's timers");
			m->deadlines = m->intervals + n;
			int64_t now = zane_now();
			const int64_t *every = (const int64_t *)ZL_ITEMS(sources);
			for (int64_t i = 0; i < n; i++) {
				m->intervals[i] = every[i];
				m->deadlines[i] = every[i] < 1 ? now : zane_later(now, 1, every[i]);
			}
			m->timers = n;
		}
	}
	pthread_mutex_lock(&p->lock);
	m->before = p->last_member;
	if (p->last_member) p->last_member->after = m;
	else p->members = m;
	p->last_member = m;
	p->live++;
	pthread_mutex_lock(&zane_ready);
	zane_queue(&m->job);
	pthread_mutex_unlock(&zane_ready);
	pthread_mutex_unlock(&p->lock);
	zane_pool_wake();
}

/* An event published to the pool whose work is running (§6.5): copied
   into the funnel's queue, whose funnel is queued when it is idle. The
   event's size and type must be the pool's, which only a publish function
   value carried out of its pool's work can break. The type is compared by
   `id`, so an event made in one object is the pool's when another object
   made the pool; its walks are the pool's own. */
void zane_workers_publish(char *event, int64_t size, int64_t id) {
	zane_workers *p = zane_self ? zane_self->workers : NULL;
	if (!p || p->event_size != size || p->event_id != id) {
		zane_flush_output();
		fputs("a worker pool's publish function was called outside the work of its pool\n", stderr);
		exit(1);
	}
	/* A pool built without state has no funnel: a stateful step on it can
	   only publish `Unit`s, which change nothing. */
	if (!p->funnel_thunk) return;
	zane_event *e = malloc(sizeof *e + (size_t)(size < 8 ? 8 : size));
	if (!e) zane_broken("out of memory for an event");
	e->next = NULL;
	e->size = size;
	memcpy(e + 1, event, (size_t)size);
	pthread_mutex_lock(&p->queue_lock);
	const zane_type *type = p->event_type;
	if (type) {
		zane_claim(&p->queue_mark);
		zane_work w;
		zane_work_start(&w);
		type->copy((char *)(e + 1), (char *)&p->queue_mark, 0, &w, 0);
		zane_work_run(&w);
	}
	if (p->last) p->last->next = e;
	else p->first = e;
	p->last = e;
	int queue = !__atomic_load_n(&p->funnel_busy, __ATOMIC_ACQUIRE);
	if (queue) {
		__atomic_store_n(&p->funnel_busy, 1, __ATOMIC_RELEASE);
		pthread_mutex_lock(&zane_ready);
		zane_queue(&p->funnel_job);
		pthread_mutex_unlock(&zane_ready);
	}
	pthread_mutex_unlock(&p->queue_lock);
	if (queue) zane_pool_wake();
}

/* A snapshot of the state (§6.6): its bytes in a buffer of this thread's,
   which the caller reads before it calls here again, and its blocks
   copied into the innermost scope, as a fresh value's are made. */
static _Thread_local char *zane_state_buffer;
static _Thread_local int64_t zane_state_room;

/* Frees this thread's snapshot buffer, as the thread stops. */
void zane_workers_thread_stop(void) {
	free(zane_state_buffer);
	zane_state_buffer = NULL;
	zane_state_room = 0;
}

char *zane_workers_state(char *handle) {
	zane_workers *p = zane_workers_at(handle);
	int64_t size = p->state_size < 16 ? 16 : p->state_size;
	if (zane_state_room < size) {
		free(zane_state_buffer);
		zane_state_buffer = malloc((size_t)size);
		if (!zane_state_buffer) zane_broken("out of memory for a state snapshot");
		zane_state_room = size;
	}
	if (!p->state) return zane_state_buffer;
	pthread_mutex_lock(&p->state_lock);
	memcpy(zane_state_buffer, p->state, (size_t)p->state_size);
	zane_copy(zane_state_buffer, p->state_type);
	pthread_mutex_unlock(&p->state_lock);
	return zane_state_buffer;
}

/* A list of a snapshot of each element (§6.6), in the order they started,
   each taken whole between two calls of its step. */
void zane_workers_elements(zane_list *out, char *handle, int64_t stride, const zane_type *type) {
	zane_workers *p = zane_workers_at(handle);
	zane_list_new(out);
	pthread_mutex_lock(&p->lock);
	for (zane_member *m = p->members; m; m = m->after) {
		pthread_mutex_lock(&m->lock);
		char *slot = zane_list_push(out, stride);
		int64_t n = m->size < stride ? m->size : stride;
		memcpy(slot, m->value, (size_t)n);
		memset(slot + n, 0, (size_t)(stride - n));
		zane_copy(slot, type);
		pthread_mutex_unlock(&m->lock);
	}
	pthread_mutex_unlock(&p->lock);
}

/* A pool's end, the free thunk of its handle (§6.7): it waits until every
   element's step has returned false and the funnel has applied every
   event, running the pool's queued jobs itself meanwhile, so it never
   waits for work only its own thread could run. Then its state and its
   regions go. */
void zane_workers_free(void *const *args, void *result) {
	(void)result;
	zane_workers *p = *(zane_workers *const *)args[0];
	pthread_mutex_lock(&p->lock);
	while (!zane_pool_finished(p)) {
		pthread_mutex_unlock(&p->lock);
		if (!zane_workers_run_one(p)) {
			pthread_mutex_lock(&p->lock);
			if (zane_pool_finished(p)) break;
			int64_t next = zane_workers_next_deadline();
			int64_t soon = zane_now() + 2000000;
			zane_wait_until(&p->done, &p->lock, next >= 0 && next < soon ? next : soon);
			continue;
		}
		pthread_mutex_lock(&p->lock);
	}
	pthread_mutex_unlock(&p->lock);
	zane_region_end(&p->state_mark, p->state, p->state_type);
	zane_region_end(&p->queue_mark, NULL, NULL);
	pthread_mutex_destroy(&p->lock);
	pthread_mutex_destroy(&p->state_lock);
	pthread_mutex_destroy(&p->queue_lock);
	pthread_cond_destroy(&p->done);
	free(p);
}
