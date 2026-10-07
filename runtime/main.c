#include "zane_internal.h"

/* A mistake of the compiler's, not the program's: the program stops. */
void zane_broken(const char *what) {
	fflush(stdout);
	fprintf(stderr, "zane runtime: %s\n", what);
	abort();
}

/* The program's arguments after its own name (effects.md §6.6), as
   `zane_arguments` hands them out: on Windows the command line converted
   from UTF-16 to UTF-8, elsewhere the bytes the system passed. */
int zane_argc;
char **zane_argv;

#ifdef _WIN32
#include <windows.h>
#include <shellapi.h>

static void zane_keep_arguments(int argc, char **argv) {
	(void)argc;
	(void)argv;
	int count;
	wchar_t **wide = CommandLineToArgvW(GetCommandLineW(), &count);
	if (!wide) zane_broken("reading the command line");
	zane_argv = malloc(sizeof *zane_argv * (size_t)(count > 0 ? count : 1));
	if (!zane_argv) zane_broken("out of memory for the arguments");
	for (int i = 1; i < count; i++) {
		int size = WideCharToMultiByte(CP_UTF8, 0, wide[i], -1, NULL, 0, NULL, NULL);
		char *text = size > 0 ? malloc((size_t)size) : NULL;
		if (!text || !WideCharToMultiByte(CP_UTF8, 0, wide[i], -1, text, size, NULL, NULL))
			zane_broken("converting an argument to UTF-8");
		zane_argv[i - 1] = text;
	}
	zane_argc = count > 0 ? count - 1 : 0;
	zane_argv[zane_argc] = NULL;
	LocalFree(wide);
}
#else
static void zane_keep_arguments(int argc, char **argv) {
	zane_argc = argc > 0 ? argc - 1 : 0;
	zane_argv = argc > 0 ? argv + 1 : argv;
}
#endif

/* A program whose output did not all reach stdout did not succeed: a write
   that failed earlier leaves the stream's error indicator set, even when the
   final flush has nothing left to fail on. The program's own scope is open
   around `main`, and when it returns every other scope has drained, and
   every call it spawned has returned. What its own region still holds --
   the package constants and what they own -- goes with the program. On Windows stdout and stderr start in
   text mode, which would write each `\n` as `\r\n`; a program writes the
   bytes it says, as it does everywhere else. */
int main(int argc, char **argv) {
	zane_keep_arguments(argc, argv);
#ifdef _WIN32
	_setmode(_fileno(stdout), _O_BINARY);
	_setmode(_fileno(stderr), _O_BINARY);
#endif
	zane_self = zane_context_new();
	zane_scope_enter();
	zane_program = zane_mark_at(zane_self, 0);
	zane_main();
	if (zane_self->depth != 1) zane_broken("a scope was left without draining");
	return fflush(stdout) == 0 && !ferror(stdout) ? 0 : 1;
}
