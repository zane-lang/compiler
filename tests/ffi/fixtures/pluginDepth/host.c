/* A host whose call nests too deep (packages.md §8.1): the stop ends its
   whole process, so it prints the first call's result and never the
   second's. A library named without a directory is the file of that name
   beside the host. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif

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

int main(int argc, char **argv) {
	if (argc < 2) return 2;
	void *library = open_library(argv[0], argv[1]);
	if (!library) {
		fprintf(stderr, "cannot load %s\n", argv[1]);
		return 2;
	}
	int64_t (*nest)(int64_t) = (int64_t (*)(int64_t))find(library, "depth_nest");
	printf("2 deep: %lld\n", (long long)nest(2));
	fflush(stdout);
	printf("100 deep: %lld\n", (long long)nest(100));
	fflush(stdout);
	return 0;
}
