#include "zane_internal.h"

/* ---------------------------------------------------------------------- */
/* Spawned calls (concurrency.md §3–4, docs/design/lowering.md §9)               */
/* ---------------------------------------------------------------------- */

int zane_state(zane_task *t) { return __atomic_load_n(&t->state, __ATOMIC_ACQUIRE); }
void zane_set_state(zane_task *t, int s) {
	__atomic_store_n(&t->state, s, __ATOMIC_RELEASE);
}

zane_deque zane_deques[ZANE_DEQUES];
static int64_t zane_slots = 1;              /* deques made, the first included */
static _Thread_local int64_t zane_mine;     /* this thread's deque, or the first */

/* The pool's threads, started with the first spawn. It keeps `wanted` of
   them, one per processor until the program sets a number, and a thread
   over that number leaves when it next finds no work. `queued` counts the
   calls in every deque, and a thread sleeps only while there are none. */
pthread_mutex_t zane_pool = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t zane_waiting = PTHREAD_COND_INITIALIZER;
pthread_cond_t zane_finished = PTHREAD_COND_INITIALIZER;
static int zane_started;
int64_t zane_threads, zane_wanted, zane_queued;

/* A queued call taken out of its deque to run; the deque's lock is held. */
void zane_unlink(zane_deque *d, zane_task *t) {
	if (t->before) t->before->after = t->after;
	else d->first = t->after;
	if (t->after) t->after->before = t->before;
	else d->last = t->before;
	t->before = t->after = NULL;
	zane_set_state(t, ZANE_RUNNING);
}

void zane_taken(void) {
	pthread_mutex_lock(&zane_pool);
	zane_queued--;
	pthread_mutex_unlock(&zane_pool);
}

/* The newest call in a deque, or its oldest. */
static zane_task *zane_pop(zane_deque *d, int newest) {
	pthread_mutex_lock(&d->lock);
	zane_task *t = newest ? d->last : d->first;
	if (t) zane_unlink(d, t);
	pthread_mutex_unlock(&d->lock);
	if (t) zane_taken();
	return t;
}

/* Work for this thread: its own newest call, or another deque's oldest. */
static zane_task *zane_find(void) {
	zane_task *t = zane_mine ? zane_pop(&zane_deques[zane_mine], 1) : NULL;
	int64_t slots = __atomic_load_n(&zane_slots, __ATOMIC_ACQUIRE);
	for (int64_t k = 1; !t && k <= slots; k++) {
		int64_t i = (zane_mine + k) % slots;
		if (i != zane_mine || !zane_mine) t = zane_pop(&zane_deques[i], 0);
	}
	return t;
}

/* A call run on this thread, in a context of its own whose first scope
   holds its result's blocks until the result comes home. */
void zane_run(zane_task *t) {
	zane_context *outer = zane_self;
	zane_self = t->context = zane_context_new();
	zane_scope_enter();
	t->run(t->frame);
	zane_self = outer;
	pthread_mutex_lock(&zane_pool);
	zane_set_state(t, ZANE_DONE);
	pthread_cond_broadcast(&zane_finished);
	pthread_mutex_unlock(&zane_pool);
}

/* A pool thread takes over a deque no thread keeps, or a new one; the
   pool's lock is held. */
static int64_t zane_keep(void) {
	for (int64_t i = 1; i < zane_slots; i++)
		if (!zane_deques[i].kept) {
			zane_deques[i].kept = 1;
			return i;
		}
	if (zane_slots == ZANE_DEQUES) zane_broken("more threads than the pool keeps");
	pthread_mutex_init(&zane_deques[zane_slots].lock, NULL);
	zane_deques[zane_slots].kept = 1;
	__atomic_store_n(&zane_slots, zane_slots + 1, __ATOMIC_RELEASE);
	return zane_slots - 1;
}

static void *zane_worker(void *deque) {
	zane_mine = (int64_t)(intptr_t)deque;
	for (;;) {
		zane_task *t = zane_find();
		if (t) {
			zane_run(t);
			continue;
		}
		pthread_mutex_lock(&zane_pool);
		while (zane_queued <= 0 && zane_threads <= zane_wanted)
			pthread_cond_wait(&zane_waiting, &zane_pool);
		if (zane_threads > zane_wanted) {
			zane_threads--;
			zane_deques[zane_mine].kept = 0;
			pthread_mutex_unlock(&zane_pool);
			return NULL;
		}
		pthread_mutex_unlock(&zane_pool);
	}
}

/* One thread for each processor. */
int64_t zane_processors(void) {
#ifdef _WIN32
	long n = pthread_num_processors_np();
#else
	long n = sysconf(_SC_NPROCESSORS_ONLN);
#endif
	return n < 1 ? 1 : n;
}

/* Threads started until the pool has as many as it wants, and those over
   it woken to leave; the pool's lock is held. */
static void zane_fill(void) {
	for (; zane_threads < zane_wanted; zane_threads++) {
		pthread_t thread;
		void *deque = (void *)(intptr_t)zane_keep();
		if (pthread_create(&thread, NULL, zane_worker, deque) != 0)
			zane_broken("no thread for the pool");
		pthread_detach(thread);
	}
	pthread_cond_broadcast(&zane_waiting);
}

static void zane_start(void) {
	pthread_mutex_init(&zane_deques[0].lock, NULL);
	if (!zane_wanted) zane_wanted = zane_processors();
	zane_started = 1;
	zane_fill();
}

/* `@runtime$Runtime`'s `setThreads` and `setThreadsAuto` (§2.4): the pool
   resized, now or when it starts. A count below one resizes nothing, and
   the call aborts: 0 says so. The pool keeps at most one thread fewer than
   it has deques. */
int64_t zane_set_threads(int64_t count) {
	if (count < 1) return 0;
	pthread_mutex_lock(&zane_pool);
	zane_wanted = count < ZANE_DEQUES - 1 ? count : ZANE_DEQUES - 1;
	if (zane_started) zane_fill();
	pthread_mutex_unlock(&zane_pool);
	return 1;
}

void zane_set_threads_auto(void) { zane_set_threads(zane_processors()); }

/* A new call's frame, `size` bytes, in the innermost scope's fixed region. */
void *zane_frame(int64_t scope, int64_t size, int64_t align) {
	zane_context *c = zane_self;
	if (scope != c->depth - 1) zane_broken("a call spawned from a scope that is not innermost");
	if (align > 8) zane_broken("a spawned call's frame aligned past a word");
	zane_lock(c);
	zane_task *t = zane_bump((int64_t)sizeof *t + size, 8);
	zane_unlock(c);
	memset(t, 0, sizeof *t);
	t->frame = (char *)(t + 1);
	return t->frame;
}

/* The call whose frame is filled starts (§3.6): the innermost scope waits
   for it, and from now its context is shared. */
void zane_spawn(char *frame, void (*run)(char *), char *dest, const int64_t *layout,
                int64_t size) {
	zane_task *t = (zane_task *)frame - 1;
	zane_context *c = zane_self;
	zane_mark *m = zane_mark_at(c, c->depth - 1);
	t->run = run;
	t->dest = dest;
	t->layout = layout;
	t->size = size;
	t->owner = c;
	t->next = m->tasks;
	m->tasks = t;
	c->shared++;
	pthread_mutex_lock(&zane_pool);
	if (!zane_started) zane_start();
	zane_queued++;
	pthread_mutex_unlock(&zane_pool);
	zane_deque *d = &zane_deques[zane_mine];
	pthread_mutex_lock(&d->lock);
	t->deque = zane_mine;
	zane_set_state(t, ZANE_QUEUED);
	t->before = d->last;
	if (d->last) d->last->after = t;
	else d->first = t;
	d->last = t;
	pthread_mutex_unlock(&d->lock);
	pthread_mutex_lock(&zane_pool);
	pthread_cond_signal(&zane_waiting);
	pthread_mutex_unlock(&zane_pool);
}
