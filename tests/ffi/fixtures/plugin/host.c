/* A host (packages.md §8.1): it loads each dynamic library it is given,
   one runtime each, and calls their exports, on its own thread and on
   threads it starts itself. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <pthread.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif

typedef struct { double x, y; } point;
typedef struct { const uint8_t *data; size_t size; } bytes;

static void *open_library(const char *path) {
#ifdef _WIN32
	return (void *)LoadLibraryA(path);
#else
	return dlopen(path, RTLD_NOW | RTLD_LOCAL);
#endif
}

static void *find(void *library, const char *name) {
#ifdef _WIN32
	return (void *)GetProcAddress((HMODULE)library, name);
#else
	return dlsym(library, name);
#endif
}

static void say(const char *text) {
	fputs(text, stdout);
	fflush(stdout);
}

static int64_t (*square)(int64_t);

static void *squares(void *arg) {
	int64_t total = 0;
	for (int64_t i = 0; i < 1000; i++) total += square(i);
	*(int64_t *)arg = total;
	return NULL;
}

static void run(void *library, const char *which) {
	char line[128];
	snprintf(line, sizeof line, "-- %s\n", which);
	say(line);
	void (*hello)(void) = (void (*)(void))find(library, "plugin_hello");
	int64_t (*count)(void) = (int64_t (*)(void))find(library, "plugin_count");
	double (*sum)(point) = (double (*)(point))find(library, "plugin_sum");
	int64_t (*pick)(_Bool, int64_t, int64_t) = (int64_t (*)(_Bool, int64_t, int64_t))find(library, "plugin_pick");
	_Bool (*less)(int64_t, int64_t) = (_Bool (*)(int64_t, int64_t))find(library, "plugin_less");
	int64_t (*echo)(bytes) = (int64_t (*)(bytes))find(library, "plugin_echo");
	int64_t (*arguments)(void) = (int64_t (*)(void))find(library, "plugin_arguments");
	int64_t (*entry)(int64_t) = (int64_t (*)(int64_t))find(library, "plugin_entry");
	square = (int64_t (*)(int64_t))find(library, "tally_square");
	hello();
	hello();
	int64_t first = count();
	int64_t second = count();
	snprintf(line, sizeof line, "count: %lld then %lld\n", (long long)first, (long long)second);
	say(line);
	point p = { 1.5, 2.25 };
	snprintf(line, sizeof line, "sum: %g\n", sum(p));
	say(line);
	snprintf(line, sizeof line, "pick: %lld %lld\n", (long long)pick(1, 3, 4), (long long)pick(0, 3, 4));
	say(line);
	snprintf(line, sizeof line, "less: %d %d\n", less(1, 2), less(2, 1));
	say(line);
	char text[] = "an echo from the host";
	bytes b = { (const uint8_t *)text, strlen(text) };
	snprintf(line, sizeof line, "echo gave %lld\n", (long long)echo(b));
	say(line);
	snprintf(line, sizeof line, "arguments: %lld\n", (long long)arguments());
	say(line);
	snprintf(line, sizeof line, "entry: %lld\n", (long long)entry(5));
	say(line);
	pthread_t threads[4];
	int64_t totals[4];
	for (int i = 0; i < 4; i++) pthread_create(&threads[i], NULL, squares, &totals[i]);
	for (int i = 0; i < 4; i++) pthread_join(threads[i], NULL);
	snprintf(line, sizeof line, "squares: %lld %lld %lld %lld\n", (long long)totals[0], (long long)totals[1],
	         (long long)totals[2], (long long)totals[3]);
	say(line);
	snprintf(line, sizeof line, "unused_nothing offered: %s\n", find(library, "unused_nothing") ? "yes" : "no");
	say(line);
	snprintf(line, sizeof line, "zane_output offered: %s\n", find(library, "zane_output") ? "yes" : "no");
	say(line);
}

int main(int argc, char **argv) {
	void *libraries[2];
	for (int i = 1; i < argc && i < 3; i++) {
		libraries[i - 1] = open_library(argv[i]);
		if (!libraries[i - 1]) {
			fprintf(stderr, "cannot load %s\n", argv[i]);
			return 1;
		}
	}
	/* Both libraries loaded at once: each has a runtime, a console and C
	   state of its own. */
	run(libraries[0], "unoptimized");
	run(libraries[1], "optimized");
	return 0;
}
