#include "zane_internal.h"

#include <errno.h>
#include <sys/stat.h>

#ifdef _WIN32
#include <windows.h>
#include <shellapi.h>
#else
#include <fcntl.h>
#include <sys/socket.h>
#endif

/* ---------------------------------------------------------------------- */
/* The program's output (effects.md §6.6, docs/design/lowering.md §9)     */
/* ---------------------------------------------------------------------- */

/* What the program prints waits in a buffer of the runtime's own, so that
   the fault handler can flush it with only async-signal-safe calls. It is
   the size stdio would give stdout: the block size `fstat` reports for it,
   or BUFSIZ. It is flushed when it fills and when the program ends, and,
   when stdout is a terminal, at every print that writes a newline, as
   stdio flushes a terminal's lines. Writers take the mutex, and touch the
   buffer only once they have claimed `busy`, from 0 (free) to 1. The fault
   path claims it from 0 to 2 without the mutex, so a writer that holds the
   mutex and has not claimed it yet has not touched the buffer; a writer
   that finds 2 waits for the program to end. A write that fails drops what
   it held and marks the output failed. */
static char *zane_out;
static size_t zane_out_size, zane_out_used;
static pthread_mutex_t zane_out_lock = PTHREAD_MUTEX_INITIALIZER;
static int zane_out_busy, zane_out_terminal, zane_out_failed;

static void zane_output_start(void) {
#ifdef _WIN32
	zane_out_size = BUFSIZ;
	zane_out_terminal = _isatty(1);
#else
	struct stat s;
	zane_out_size = fstat(1, &s) == 0 && s.st_blksize > 0 ? (size_t)s.st_blksize : BUFSIZ;
	zane_out_terminal = isatty(1);
#endif
	zane_out = malloc(zane_out_size);
	if (!zane_out) zane_broken("out of memory for the output buffer");
}

/* `n` bytes from `at` written to stdout whole, or 0. */
static int zane_write_out(const char *at, size_t n) {
#ifdef _WIN32
	HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
	while (n > 0) {
		DWORD written;
		if (!WriteFile(out, at, n > (1u << 30) ? 1u << 30 : (DWORD)n, &written, NULL) || written == 0)
			return 0;
		at += written;
		n -= written;
	}
#else
	while (n > 0) {
		ssize_t written = write(1, at, n);
		if (written < 0 && errno == EINTR) continue;
		if (written <= 0) return 0;
		at += written;
		n -= (size_t)written;
	}
#endif
	return 1;
}

/* The buffer, claimed, written out. */
static void zane_out_flush(void) {
	if (zane_out_used > 0 && !zane_write_out(zane_out, zane_out_used)) zane_out_failed = 1;
	zane_out_used = 0;
}

/* The buffer claimed by a writer, which holds the mutex. */
static void zane_out_claim(void) {
	int idle = 0;
	if (__atomic_compare_exchange_n(&zane_out_busy, &idle, 1, 0, __ATOMIC_ACQUIRE, __ATOMIC_RELAXED)) return;
	/* The fault path has it, and the program is stopping. */
	for (;;) {
#ifdef _WIN32
		Sleep(INFINITE);
#else
		pause();
#endif
	}
}

static void zane_out_release(void) {
	__atomic_store_n(&zane_out_busy, 0, __ATOMIC_RELEASE);
	pthread_mutex_unlock(&zane_out_lock);
}

void zane_output(const char *bytes, size_t n) {
	pthread_mutex_lock(&zane_out_lock);
	zane_out_claim();
	int line = zane_out_terminal && memchr(bytes, '\n', n) != NULL;
	while (n > 0) {
		size_t room = zane_out_size - zane_out_used, part = n < room ? n : room;
		memcpy(zane_out + zane_out_used, bytes, part);
		zane_out_used += part;
		bytes += part;
		n -= part;
		if (zane_out_used == zane_out_size) zane_out_flush();
	}
	if (line) zane_out_flush();
	zane_out_release();
}

/* Everything printed so far written out, on the paths that end the
   program normally: 1 when all of the program's output reached stdout. */
int zane_flush_output(void) {
	pthread_mutex_lock(&zane_out_lock);
	zane_out_claim();
	zane_out_flush();
	int ok = !zane_out_failed;
	zane_out_release();
	return ok;
}

/* The buffer flushed from the fault handler, with only async-signal-safe
   calls, and never blocking: when another thread holds the buffer, or the
   faulting thread was printing, it is left, and so is output stdout cannot
   take without blocking. Another process may fill a pipe between a check
   and a write, so a pipe or a socket is written only through a descriptor
   that cannot block: a socket with `MSG_DONTWAIT`, and on Linux a pipe
   through a description of its own, opened from `/proc/self/fd/1`, so that
   no process sharing fd 1 sees the flag. Elsewhere a pipe's output is
   dropped. On Windows, where a pipe offers no way to ask, only a terminal
   or a file is written. */
void zane_flush_output_in_fault(void) {
	int idle = 0;
	if (!__atomic_compare_exchange_n(&zane_out_busy, &idle, 2, 0, __ATOMIC_ACQUIRE, __ATOMIC_RELAXED)) return;
	const char *at = zane_out;
	size_t n = zane_out_used;
	if (n == 0) return;
#ifdef _WIN32
	DWORD type = GetFileType(GetStdHandle(STD_OUTPUT_HANDLE));
	if (type == FILE_TYPE_CHAR || type == FILE_TYPE_DISK) zane_write_out(at, n);
#else
	struct stat s;
	if (fstat(1, &s) != 0) return;
	if (S_ISSOCK(s.st_mode)) {
		while (n > 0) {
#ifdef MSG_NOSIGNAL
			ssize_t sent = send(1, at, n, MSG_DONTWAIT | MSG_NOSIGNAL);
#else
			ssize_t sent = send(1, at, n, MSG_DONTWAIT);
#endif
			if (sent < 0 && errno == EINTR) continue;
			if (sent <= 0) return;
			at += sent;
			n -= (size_t)sent;
		}
	} else if (S_ISFIFO(s.st_mode)) {
#ifdef __linux__
		int fd = open("/proc/self/fd/1", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
		if (fd < 0) return;
		while (n > 0) {
			ssize_t written = write(fd, at, n);
			if (written < 0 && errno == EINTR) continue;
			if (written <= 0) break;
			at += written;
			n -= (size_t)written;
		}
		close(fd);
#endif
	} else {
		zane_write_out(at, n);
	}
#endif
}

/* A mistake of the compiler's, not the program's: the program stops. */
void zane_broken(const char *what) {
	zane_flush_output();
	fprintf(stderr, "zane runtime: %s\n", what);
	abort();
}

/* The program's arguments after its own name (effects.md §6.6), as
   `zane_arguments` hands them out: on Windows the command line converted
   from UTF-16 to UTF-8, elsewhere the bytes the system passed. */
int zane_argc;
char **zane_argv;

int zane_checking;

#ifdef _WIN32
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
   that failed earlier marks the output failed, even when the final flush
   has nothing left to fail on. The program's own scope is open
   around `main`, and when it returns every other scope has drained, and
   every call it spawned has returned. What its own region still holds --
   the package constants and what they own -- goes with the program. On Windows stdout and stderr start in
   text mode, which would write each `\n` as `\r\n`; a program writes the
   bytes it says, as it does everywhere else. */
int main(int argc, char **argv) {
	zane_keep_arguments(argc, argv);
	const char *check = getenv("ZANE_CHECK");
	zane_checking = check && *check && strcmp(check, "0") != 0;
#ifdef _WIN32
	_setmode(_fileno(stdout), _O_BINARY);
	_setmode(_fileno(stderr), _O_BINARY);
#endif
	zane_output_start();
	zane_regions_start();
	zane_thread_start();
	zane_self = zane_context_new();
	zane_program = zane_scope_enter(0);
	zane_main();
	if (zane_self->top != zane_program) zane_broken("a scope was left without draining");
	zane_tier_end();
	return zane_flush_output() ? 0 : 1;
}
