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

/* A queued call taken out of its deque to run; the deque's lock is held.
   It leaves the count as it leaves the deque, so a thread that reads a
   count above zero finds a call to take. */
void zane_unlink(zane_deque *d, zane_task *t) {
	if (t->before) t->before->after = t->after;
	else d->first = t->after;
	if (t->after) t->after->before = t->before;
	else d->last = t->before;
	t->before = t->after = NULL;
	__atomic_sub_fetch(&zane_queued, 1, __ATOMIC_RELAXED);
	zane_set_state(t, ZANE_RUNNING);
}

/* The newest call in a deque, or its oldest. */
static zane_task *zane_pop(zane_deque *d, int newest) {
	pthread_mutex_lock(&d->lock);
	zane_task *t = newest ? d->last : d->first;
	if (t) zane_unlink(d, t);
	pthread_mutex_unlock(&d->lock);
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
	zane_context *c = zane_context_new();
	/* A joiner following its wait reads the context from here (value.c). */
	__atomic_store_n(&t->context, c, __ATOMIC_RELEASE);
	zane_self = c;
	zane_scope_enter(0);
	t->run(t->frame);
	zane_self = outer;
	zane_reopen();
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
	zane_thread_start();
	for (;;) {
		zane_task *t = zane_find();
		if (t) {
			zane_run(t);
			continue;
		}
		pthread_mutex_lock(&zane_pool);
		while (__atomic_load_n(&zane_queued, __ATOMIC_RELAXED) <= 0 && zane_threads <= zane_wanted)
			pthread_cond_wait(&zane_waiting, &zane_pool);
		if (zane_threads > zane_wanted) {
			zane_threads--;
			zane_deques[zane_mine].kept = 0;
			pthread_mutex_unlock(&zane_pool);
			zane_thread_stop();
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
   it woken to leave; the pool's lock is held. Each has 8 MiB of machine
   stack, what the program's own thread has, where systems give a thread
   they start anything from 512 KiB to 8 MiB (docs/design/platforms.md). */
static void zane_fill(void) {
	pthread_attr_t attributes;
	pthread_attr_init(&attributes);
	pthread_attr_setstacksize(&attributes, (size_t)8 << 20);
	for (; zane_threads < zane_wanted; zane_threads++) {
		pthread_t thread;
		void *deque = (void *)(intptr_t)zane_keep();
		if (pthread_create(&thread, &attributes, zane_worker, deque) != 0)
			zane_broken("no thread for the pool");
		pthread_detach(thread);
	}
	pthread_attr_destroy(&attributes);
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

/* Experimental (zane_island): the subject region made for the call about
   to be spawned on this thread, which zane_spawn hands it. */
#ifdef ZANE_SUBJECT_REGIONS
static _Thread_local zane_island *zane_pending_island;
#endif

/* The subject at `*field`, `size` bytes of `type`, goes into a region of
   its own for the call about to be spawned, and `*field` names it there. A
   local takes the region it had for the last call spawned on it, if its
   scope still holds one, so what is already there stays. While no other
   call this context spawned is out, nothing else can be reading the
   subject, so it moves in; otherwise it is copied there whole, since a
   call spawned before may still read it where it is, so its blocks stay
   as they are until the join. A copy made for this call alone (`copied`)
   always moves. Without ZANE_SUBJECT_REGIONS lowering never calls this. */
void zane_island_make(char **field, int64_t size, const zane_type *type, int64_t copied) {
#ifdef ZANE_SUBJECT_REGIONS
	zane_context *c = zane_self;
	char *home = *field;
	zane_island *i = NULL;
	if (!copied)
		for (zane_island *k = c->islands; k && !i; k = k->next)
			if (!k->task && k->scope && k->home == home) i = k;
	if (!i) {
		if (!(i = calloc(1, sizeof *i))) zane_broken("out of memory for a subject region");
		i->mark.context = c;
		i->mark.depth = ZANE_ISLAND_DEPTH;
		if (!copied && (zane_page_entry(home) & 1)) {
			i->scope = zane_region_at(home);
			i->next = c->islands;
			c->islands = i;
		}
	}
	i->home = home;
	i->type = type;
	i->target = NULL;
	if (!i->value || i->size < size) {
		i->value = zane_alloc_held(&i->mark, size < 8 ? 8 : size, 16);
		i->mark.heap.live--;
	}
	i->size = size;
	memcpy(i->value, home, (size_t)size);
	i->moved = copied || c->shared == 0;
	if (i->moved) {
		zane_move(i->value, type, &i->mark, 0);
	} else if (type) {
		zane_work w;
		zane_work_start(&w);
		type->copy(i->value, (char *)&i->mark, 0, &w, 0);
		zane_work_run(&w);
	}
	*field = i->value;
	zane_pending_island = i;
#else
	(void)field;
	(void)size;
	(void)type;
	(void)copied;
	zane_broken("a subject region without ZANE_SUBJECT_REGIONS");
#endif
}

#ifdef ZANE_SUBJECT_REGIONS
/* The joined call's subject regions, on the joining thread, the context's
   own, once the call is done. A subject copied from a place reached
   through an owner is written back there, and its region's chunks are
   given back. A subject copied in from a local leaves the local's old
   value behind: ended now when no other call is out, so none can be
   following it, and otherwise kept until its region drains, a checked
   drain ending it there, as a write-back's replaced value. The subject
   then goes home. A local's region stays for the next call on it, its
   chunks listed on its scope; any other subject's chunks become its home
   region's. */
void zane_islands_home(zane_task *t) {
	zane_context *c = zane_self;
	for (zane_island **at = &c->islands; *at;) {
		zane_island *i = *at;
		if (i->task != t) {
			at = &i->next;
			continue;
		}
		i->task = NULL;
		zane_mark *r = &i->mark;
		if (i->target) {
			*at = i->next;
			zane_writeback(i->target, i->value, i->size, i->type);
			zane_unmap(r);
			free(i);
			continue;
		}
		if (i->home == i->value) {
			*at = i->next;
			zane_unmap(r);
			free(i);
			continue;
		}
		zane_mark *home = i->scope ? i->scope : zane_region_at(i->home);
		if (!i->moved && i->type) {
			if (c->shared == 1) {
				zane_end(i->home, i->type);
			} else if (zane_checking) {
				zane_retired *old = (zane_retired *)zane_alloc(home, (int64_t)sizeof *old + i->size, 8);
				memcpy(old + 1, i->home, (size_t)i->size);
				old->type = i->type;
				old->size = i->size;
				old->next = home->retired;
				home->retired = old;
			}
		}
		memcpy(i->home, i->value, (size_t)i->size);
		/* A call spawned on this subject in turn retired its old value
		   here; it ends where the chunks drain. */
		while (r->retired) {
			zane_retired *v = r->retired;
			r->retired = v->next;
			v->next = home->retired;
			home->retired = v;
		}
		while (r->mappings) {
			zane_mapping *m = r->mappings;
			r->mappings = m->next;
			if (!i->scope)
				for (size_t off = 0; off < m->size; off += ZANE_CHUNK) zane_set_page((char *)m + off, (uintptr_t)home);
			m->next = home->mappings;
			home->mappings = m;
		}
		if (i->scope) {
			at = &i->next;
			continue;
		}
		home->heap.live += r->heap.live;
		*at = i->next;
		free(i);
	}
}

/* Scope `m` of context `c` drains: the regions it kept for its locals'
   calls go, their chunks with its own. A checked drain finds none of their
   blocks out, since each local that owned one has ended. */
void zane_islands_drained(zane_context *c, zane_mark *m) {
	for (zane_island **at = &c->islands; *at;) {
		zane_island *i = *at;
		if (i->scope != m) {
			at = &i->next;
			continue;
		}
		if (zane_checking && i->mark.heap.live != 0) zane_broken("a dynamic block outlived its owner");
		*at = i->next;
		free(i);
	}
}
#endif

/* The call whose frame is filled starts (§3.6): the innermost scope waits
   for it, and from now its context is shared. Its frame is in that scope's
   own, after a zeroed `zane_task` that lowering left room for. */
void zane_spawn(char *frame, void (*run)(char *), char *dest, const zane_type *type,
                int64_t size) {
	zane_task *t = (zane_task *)frame - 1;
	zane_context *c = zane_self;
	zane_mark *m = c->top;
	t->frame = frame;
	t->run = run;
	t->dest = dest;
	t->type = type;
	t->size = size;
	t->owner = c;
	__atomic_store_n(&t->context, NULL, __ATOMIC_RELAXED);
	t->next = m->tasks;
	m->tasks = t;
	c->shared++;
#ifdef ZANE_SUBJECT_REGIONS
	if (zane_pending_island) {
		zane_pending_island->task = t;
		/* A local's region is listed from when it is made. */
		if (!zane_pending_island->scope) {
			zane_pending_island->next = c->islands;
			c->islands = zane_pending_island;
		}
		zane_pending_island = NULL;
	}
#else
	zane_open = NULL;
#endif
	pthread_mutex_lock(&zane_pool);
	if (!zane_started) zane_start();
	pthread_mutex_unlock(&zane_pool);
	zane_deque *d = &zane_deques[zane_mine];
	pthread_mutex_lock(&d->lock);
	t->deque = zane_mine;
	zane_set_state(t, ZANE_QUEUED);
	t->before = d->last;
	if (d->last) d->last->after = t;
	else d->first = t;
	d->last = t;
	/* Counted once it is in the deque, and before the signal: a thread
	   that read the count before waits by now, and is woken. */
	__atomic_add_fetch(&zane_queued, 1, __ATOMIC_RELAXED);
	pthread_mutex_unlock(&d->lock);
	pthread_mutex_lock(&zane_pool);
	pthread_cond_signal(&zane_waiting);
	pthread_mutex_unlock(&zane_pool);
}
