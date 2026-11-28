/* A host that holds two Zane objects (packages.md §8.5): it makes them,
   writes and reads them, reads the list one of them lends it as a view
   until its next mutable call, and ends both, the second-made first. A
   library named without a directory is the file of that name beside the
   host. */
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif

typedef struct {
	const void *data;
	size_t count;
} view;

static void *open_library(const char *host, const char *name) {
	char path[4096];
	const char *slash = NULL;
	for (const char *c = host; *c; c++)
		if (*c == '/' || *c == '\\') slash = c;
	if (strchr(name, '/') || strchr(name, '\\')) snprintf(path, sizeof path, "%s", name);
	else if (slash) snprintf(path, sizeof path, "%.*s/%s", (int)(slash - host), host, name);
	else snprintf(path, sizeof path, "./%s", name);
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

static void print_view(const char *label, view v) {
	printf("%s:", label);
	for (size_t i = 0; i < v.count; i++) printf(" %lld", (long long)((const int64_t *)v.data)[i]);
	printf("\n");
}

static int run(const char *host, const char *name) {
	void *library = open_library(host, name);
	if (!library) {
		fprintf(stderr, "cannot load %s\n", name);
		return 2;
	}
	void *(*make)(int64_t) = (void *(*)(int64_t))find(library, "tally_new");
	void (*add)(void *, int64_t) = (void (*)(void *, int64_t))find(library, "tally_add");
	int64_t (*total)(const void *) = (int64_t (*)(const void *))find(library, "tally_total");
	int64_t (*sum)(const void *, const void *) = (int64_t (*)(const void *, const void *))find(library, "tally_sum");
	view (*seen)(void *) = (view (*)(void *))find(library, "tally_seen");
	void (*end)(void *) = (void (*)(void *))find(library, "tally_end");
	void *a = make(10), *b = make(100);
	for (int64_t i = 1; i <= 40; i++) add(a, i);
	add(b, 5);
	printf("total a: %lld, b: %lld, sum: %lld\n", (long long)total(a), (long long)total(b), (long long)sum(a, b));
	view first = seen(b);
	print_view("b seen", first);
	add(b, 6);
	view second = seen(b);
	print_view("b seen again", second);
	view many = seen(a);
	printf("a seen %zu, last %lld\n", many.count, (long long)((const int64_t *)many.data)[many.count - 1]);
	fflush(stdout);
	end(b);
	end(a);
	fflush(stdout);
	return 0;
}

int main(int argc, char **argv) {
	for (int i = 1; i < argc; i++) {
		int status = run(argv[0], argv[i]);
		if (status) return status;
	}
	return 0;
}
