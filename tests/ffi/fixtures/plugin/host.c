/* A host (packages.md §8.1): it loads each dynamic library it is given,
   one runtime each, and calls their exports, on its own thread and on
   threads it starts itself. A library named without a directory is the
   file of that name beside the host, so the host finds its libraries
   wherever dev/bin/check-programs runs it. The test runs it with the
   unoptimized library first and with the optimized library first, so the two
   load in either order. */
#define _POSIX_C_SOURCE 200809L
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

static void *open_library(const char *host, const char *name) {
	char path[4096];
	const char *slash = NULL;
	if (!strchr(name, '/') && !strchr(name, '\\')) {
		for (const char *c = host; *c; c++)
			if (*c == '/' || *c == '\\') slash = c;
	}
	if (slash) snprintf(path, sizeof path, "%.*s/%s", (int)(slash - host), host, name);
	else if (!strchr(name, '/') && !strchr(name, '\\')) snprintf(path, sizeof path, "./%s", name);
	else snprintf(path, sizeof path, "%s", name);
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
	int64_t (*pair)(int64_t) = (int64_t (*)(int64_t))find(library, "tally_pair");
	snprintf(line, sizeof line, "pair: %lld\n", (long long)pair(20));
	say(line);
	snprintf(line, sizeof line, "unused_nothing offered: %s\n", find(library, "unused_nothing") ? "yes" : "no");
	say(line);
	snprintf(line, sizeof line, "zane_output offered: %s\n", find(library, "zane_output") ? "yes" : "no");
	say(line);
	/* The root's thread-local variable, offered under its C name as a
	   thread-local alias: the host's write through it is what the
	   library's C reads on the same thread. A DLL cannot export a
	   thread-local variable, so Windows offers none. */
	int64_t *seen = (int64_t *)find(library, "plugin_seen");
	int64_t (*seen_twice)(void) = (int64_t (*)(void))find(library, "plugin_seen_twice");
#ifdef _WIN32
	int right = !seen;
#else
	int right = seen && (*seen = 21, seen_twice() == 42);
#endif
	(void)seen_twice;
	say(right ? "plugin_seen: right\n" : "plugin_seen: wrong\n");
}

int main(int argc, char **argv) {
	void *libraries[2];
	for (int i = 1; i < argc && i < 3; i++) {
		libraries[i - 1] = open_library(argv[0], argv[i]);
		if (!libraries[i - 1]) {
			fprintf(stderr, "cannot load %s\n", argv[i]);
			return 1;
		}
	}
	/* Both libraries loaded at once, in the order given: each has a
	   runtime, a console and C state of its own. */
	run(libraries[0], "first library");
	run(libraries[1], "second library");
	/* Unloaded by the host, each library stays loaded until the process
	   ends: loading the file again reaches the same runtime, whose count
	   goes on from where it was. */
	for (int i = 0; i < 2; i++) {
#ifdef _WIN32
		FreeLibrary((HMODULE)libraries[i]);
#else
		dlclose(libraries[i]);
#endif
	}
	for (int i = 0; i < 2; i++) {
		void *again = open_library(argv[0], argv[i + 1]);
		int64_t (*count)(void) = again ? (int64_t (*)(void))find(again, "plugin_count") : NULL;
		char line[128];
		snprintf(line, sizeof line, "reloaded, count: %lld\n", count ? (long long)count() : -1LL);
		say(line);
	}
	return 0;
}
