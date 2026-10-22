/* ---------------------------------------------------------------------- */
/* Tiered builds (docs/design/tiers.md)                                   */
/* ---------------------------------------------------------------------- */

/* Tier 0 of a tiered build calls each of its own functions through a slot,
   and its start function hands the runtime its slots and what tier 1 may
   take from it. When `ZANE_TIER_UP` names a file, a thread of the
   runtime's waits for that file, tier 1, a shared library of the same
   program optimized, loads it, and checks that it was built from the same
   module. It then fills tier 1's imports from tier 0's exports and points
   each slot at tier 1's function of the same key. A call already running
   finishes in tier 0; the next one runs tier 1. Anything that goes wrong
   leaves the program in tier 0, which means the same, and says so only
   when `ZANE_TIER_LOG` is set. `ZANE_TIER_WAIT=1` loads tier 1 before
   `main` runs, for the tests. The variables are removed once read, so
   nothing the program starts sees them. */

#include "zane_internal.h"

#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#include <sys/stat.h>
#include <time.h>
#endif

struct zane_tier_entry {
	const char *key;
	void *at;
};

/* What tier 0 hands `zane_tier_up`, and what tier 1 defines as
   `__zane_tier1` (lib/codegen/tiers.ml). Each table is sorted by key, as
   `strcmp` orders them. */
struct zane_tier0 {
	const char *hash;
	int64_t slots;
	const struct zane_tier_entry *slot;
	int64_t exports;
	const struct zane_tier_entry *export_;
};

struct zane_tier1 {
	const char *hash;
	int64_t defs;
	const struct zane_tier_entry *def;
	int64_t imports;
	const char *const *name;
	void **import;
};

static const struct zane_tier0 *zane_tier;
static char *zane_tier_path;
static int zane_tier_log;

/* Whether the thread is loading tier 1, which the program waits for before
   it ends: a process that ends while another thread loads a library can
   leave the loader's lock held. Once the program is ending, the thread
   loads nothing more. */
static pthread_mutex_t zane_tier_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t zane_tier_done = PTHREAD_COND_INITIALIZER;
static int zane_tier_loading, zane_tier_ending;

static int zane_tier_order(const void *key, const void *entry) {
	return strcmp((const char *)key, ((const struct zane_tier_entry *)entry)->key);
}

static const struct zane_tier_entry *zane_tier_find(const char *key, const struct zane_tier_entry *table, int64_t n) {
	return bsearch(key, table, (size_t)n, sizeof *table, zane_tier_order);
}

static double zane_tier_now(void) {
#ifdef _WIN32
	return (double)GetTickCount64() / 1000;
#else
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
#endif
}

static void zane_tier_say(const char *what, double since) {
	if (zane_tier_log) fprintf(stderr, "zane: tier 1 %s after %.0f ms\n", what, (zane_tier_now() - since) * 1000);
}

#ifdef _WIN32
static wchar_t *zane_tier_wide(const char *path) {
	int n = MultiByteToWideChar(CP_UTF8, 0, path, -1, NULL, 0);
	wchar_t *wide = n > 0 ? malloc(sizeof *wide * (size_t)n) : NULL;
	if (wide && !MultiByteToWideChar(CP_UTF8, 0, path, -1, wide, n)) {
		free(wide);
		return NULL;
	}
	return wide;
}

static int zane_tier_exists(const char *path) {
	wchar_t *wide = zane_tier_wide(path);
	int found = wide && GetFileAttributesW(wide) != INVALID_FILE_ATTRIBUTES;
	free(wide);
	return found;
}

static void zane_tier_pause(int ms) { Sleep((DWORD)ms); }

static const struct zane_tier1 *zane_tier_open(const char *path) {
	wchar_t *wide = zane_tier_wide(path);
	HMODULE library = wide ? LoadLibraryW(wide) : NULL;
	free(wide);
	return library ? (const struct zane_tier1 *)(void *)GetProcAddress(library, "__zane_tier1") : NULL;
}
#else
static int zane_tier_exists(const char *path) {
	struct stat s;
	return stat(path, &s) == 0;
}

static void zane_tier_pause(int ms) {
	struct timespec d = {0, (long)ms * 1000000L};
	nanosleep(&d, NULL);
}

static const struct zane_tier1 *zane_tier_open(const char *path) {
	void *library = dlopen(path, RTLD_NOW | RTLD_LOCAL);
	return library ? dlsym(library, "__zane_tier1") : NULL;
}
#endif

/* Tier 1 put in place of tier 0's functions; whether it was. */
static int zane_tier_swap(const struct zane_tier1 *t1, double since) {
	const struct zane_tier0 *t0 = zane_tier;
	if (!t1) {
		zane_tier_say("did not load", since);
		return 0;
	}
	if (strcmp(t1->hash, t0->hash) != 0) {
		zane_tier_say("is another program's", since);
		return 0;
	}
	for (int64_t i = 0; i < t1->imports; i++) {
		const struct zane_tier_entry *e = zane_tier_find(t1->name[i], t0->export_, t0->exports);
		if (!e) {
			zane_tier_say("takes what the program does not have", since);
			return 0;
		}
		t1->import[i] = e->at;
	}
	int64_t moved = 0;
	for (int64_t i = 0; i < t0->slots; i++) {
		const struct zane_tier_entry *d = zane_tier_find(t0->slot[i].key, t1->def, t1->defs);
		if (d) {
			__atomic_store_n((void **)t0->slot[i].at, d->at, __ATOMIC_RELEASE);
			moved++;
		}
	}
	if (zane_tier_log)
		fprintf(stderr, "zane: tier 1 runs %lld of %lld functions after %.0f ms\n", (long long)moved,
		        (long long)t0->slots, (zane_tier_now() - since) * 1000);
	return moved == t0->slots;
}

/* Waits for tier 1, a millisecond at a time for the first tenth of a
   second and five after, until it is there or the program ends; whether
   tier 1 then took every function. */
static int zane_tier_load(void) {
	double since = zane_tier_now();
	for (int tries = 0; !zane_tier_exists(zane_tier_path); tries++) {
		pthread_mutex_lock(&zane_tier_lock);
		int ending = zane_tier_ending;
		pthread_mutex_unlock(&zane_tier_lock);
		if (ending) return 0;
		zane_tier_pause(tries < 100 ? 1 : 5);
	}
	pthread_mutex_lock(&zane_tier_lock);
	if (zane_tier_ending) {
		pthread_mutex_unlock(&zane_tier_lock);
		return 0;
	}
	zane_tier_loading = 1;
	pthread_mutex_unlock(&zane_tier_lock);
	int swapped = zane_tier_swap(zane_tier_open(zane_tier_path), since);
	pthread_mutex_lock(&zane_tier_lock);
	zane_tier_loading = 0;
	pthread_cond_broadcast(&zane_tier_done);
	pthread_mutex_unlock(&zane_tier_lock);
	return swapped;
}

static void *zane_tier_thread(void *unused) {
	(void)unused;
	(void)zane_tier_load();
	return NULL;
}

static char *zane_tier_take(const char *name) {
	const char *value = getenv(name);
	char *copy = value && *value ? strdup(value) : NULL;
	if (value) {
#ifdef _WIN32
		_putenv_s(name, "");
#else
		unsetenv(name);
#endif
	}
	return copy;
}

void zane_tier_up(const struct zane_tier0 *tier) {
	char *log = zane_tier_take("ZANE_TIER_LOG"), *wait = zane_tier_take("ZANE_TIER_WAIT");
	zane_tier_log = log && strcmp(log, "0") != 0;
	zane_tier_path = zane_tier_take("ZANE_TIER_UP");
	zane_tier = tier;
	int now = wait && strcmp(wait, "0") != 0;
	free(log);
	free(wait);
	if (!zane_tier_path) return;
	/* A test waits for tier 1 to know the program runs it, so one that does
	   not load, or leaves a function in tier 0, stops the program. */
	if (now) {
		if (!zane_tier_load()) {
			zane_flush_output();
			fprintf(stderr, "zane: tier 1 did not take every function\n");
			exit(1);
		}
		return;
	}
	pthread_t thread;
	pthread_attr_t attr;
	pthread_attr_init(&attr);
	pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
	if (pthread_create(&thread, &attr, zane_tier_thread, NULL) != 0) zane_tier_say("had no thread to load in", zane_tier_now());
	pthread_attr_destroy(&attr);
}

/* The program is ending: the thread stops waiting, and a load under way
   finishes first. */
void zane_tier_end(void) {
	pthread_mutex_lock(&zane_tier_lock);
	zane_tier_ending = 1;
	while (zane_tier_loading) pthread_cond_wait(&zane_tier_done, &zane_tier_lock);
	pthread_mutex_unlock(&zane_tier_lock);
}
