/* The program's output buffer, tested in C on its own
   (docs/design/lowering.md §9): what a print writes reaches stdout at the
   points stdio's buffer would send it, and a stop from the fault handler
   flushes it with nothing that can deadlock or block. Each case runs in a
   child (system.h), which is stopped if it hangs, and prints `yes` when it
   held. */

#ifdef _WIN32
/* The pseudo-console a terminal case runs on, from Windows 10 on. */
#undef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif

#include "system.h"
#include "walks.h"

#ifndef _WIN32
#include <sys/stat.h>
#endif

static void check(int ok) { puts(ok ? "yes" : "no"); }

static void say(const char *s) {
	zane_text text = { (char *)s, (int64_t)strlen(s), 0 };
	zane_print(&text);
}

/* Calls nested until the machine stack is full. */
static volatile int bottom;

static int deep(int n) {
	volatile char pad[512];
	pad[0] = (char)n;
	if (bottom) return pad[0];
	say("");
	return deep(n + 1) + pad[0];
}

/* A spawned call that prints until the program stops. */
static void chatter(char *frame) {
	(void)frame;
	for (;;) say("chatter\n");
}

typedef struct {
	zane_task header;
	int64_t result;
} spawned;

static const char *const full = "recursion too deep: the machine stack is full\n";

/* The size of the runtime's output buffer for stdout as `fd`: the
   system's block size for it, or stdio's buffer on Windows (main.c). */
static size_t out_size(test_fd fd) {
#ifdef _WIN32
	(void)fd;
	return BUFSIZ;
#else
	struct stat s;
	return fstat(fd, &s) == 0 && s.st_blksize > 0 ? (size_t)s.st_blksize : BUFSIZ;
#endif
}

/* The cases a child runs. Each ends the program itself. */
static void run_child(void) {
	if (child_case("overflow-printing")) {
		/* The stack overflows in one thread while another prints, and the
		   overflowing thread prints at every call. */
		zane_set_threads(1);
		spawned s = { 0 };
		zane_spawn((char *)&s.result, chatter, NULL, NULL, 0);
		deep(0);
	} else if (child_case("overflow-full")) {
		/* Stdout is a pipe that is full and that nothing reads. */
		say("lost\n");
		deep(0);
	} else if (child_case("closed")) {
		say("nowhere\n");
		exit(zane_flush_output() ? 0 : 1);
	} else {
		/* What a print reaches stdout as, while the child waits on stdin. */
#ifdef _WIN32
		size_t size = out_size(GetStdHandle(STD_OUTPUT_HANDLE));
#else
		size_t size = out_size(STDOUT_FILENO);
#endif
		if (child_case("line")) {
			say("a line\n");
		} else {
			char *text = malloc(size + 1);
			memset(text, 'y', size);
			text[size] = 0;
			say(child_case("small") ? "small\n" : text);
			free(text);
		}
		char go;
		if (fread(&go, 1, 1, stdin) != 1) exit(2);
		exit(0);
	}
	exit(2);
}

/* The stack overflows while stdout is a pipe that is full and that nothing
   reads: the buffered output is dropped, and the program still stops. The
   pipe is filled until a write would block, by a thread on Windows, whose
   pipes cannot be asked not to. */
#ifdef _WIN32
static DWORD WINAPI filling(void *pipe) {
	char block[4096];
	memset(block, 'x', sizeof block);
	DWORD written;
	while (WriteFile((HANDLE)pipe, block, sizeof block, &written, NULL)) {}
	return 0;
}
#endif

static int overflow_into_full_pipe(void) {
	test_fd out[2];
	if (test_pipe(out) != 0) return 0;
#ifdef _WIN32
	HANDLE filler = CreateThread(NULL, 0, filling, out[1], 0, NULL);
	if (!filler) return 0;
	Sleep(500);
#else
	int flags = fcntl(out[1], F_GETFL);
	fcntl(out[1], F_SETFL, flags | O_NONBLOCK);
	char block[4096];
	memset(block, 'x', sizeof block);
	while (write(out[1], block, sizeof block) > 0) {}
	fcntl(out[1], F_SETFL, flags);
#endif
	int ok = child_stops("overflow-full", "", CHILD_TO, out[1], 1, full);
	test_close(out[0]);
#ifdef _WIN32
	/* With nothing left to read it, the filler's write fails. */
	WaitForSingleObject(filler, 5000);
	CloseHandle(filler);
#endif
	test_close(out[1]);
	return ok;
}

/* A program that forks keeps the fault handler's stack in the child
   (region.c), so a full stack there stops it as it stops the program. */
static int overflow_after_fork(void) {
#ifdef _WIN32
	return 1;
#else
	test_fd err[2];
	if (test_pipe(err) != 0) return 0;
	fflush(stdout);
	pid_t child = fork();
	if (child == 0) {
		int null = open("/dev/null", O_WRONLY);
		if (null < 0 || dup2(null, STDOUT_FILENO) < 0 || dup2(err[1], STDERR_FILENO) < 0) _exit(2);
		alarm(10);
		deep(0);
		_exit(2);
	}
	close(err[1]);
	char text[256];
	test_drain(err[0], text, sizeof text);
	close(err[0]);
	int status;
	return child > 0 && waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 1 &&
	       strcmp(text, full) == 0;
#endif
}

/* Whether `expected` bytes reached `reader` while the child waited, 0 for
   none, and the child then ended well. */
static int arrived(test_child *c, test_fd reader, size_t expected, const char *within) {
	size_t got = 0;
	static char text[1 << 16];
	while (got < expected || expected == 0) {
		long n = test_read(reader, text + got, sizeof text - 1 - got, expected ? 5000 : 300);
		if (n <= 0) break;
		got += (size_t)n;
	}
	text[got] = 0;
	int ok = within ? strstr(text, within) != NULL : expected ? got >= expected : got == 0;
	if (!child_release(c)) ok = 0;
	char err[256];
	ok &= child_ended(c, 0, err, sizeof err, 10);
	return ok;
}

/* A case run with its stdout a pipe: a short line does not arrive while
   the child waits, and output of the buffer's size does. */
static int on_pipe(const char *mode, int full_buffer) {
	test_fd out[2];
	if (test_pipe(out) != 0) return 0;
	test_child c;
	size_t size = out_size(out[1]);
	int started = child_start(&c, mode, "", CHILD_TO, out[1]);
	test_close(out[1]);
	int ok = started && arrived(&c, out[0], full_buffer ? size : 0, NULL);
	test_close(out[0]);
	return ok;
}

/* A case run on a terminal: a line arrives while the child waits. */
#ifdef _WIN32
static int on_terminal(void) {
	HANDLE in_read, in_write, out_read, out_write;
	if (!CreatePipe(&in_read, &in_write, NULL, 0)) return 0;
	if (!CreatePipe(&out_read, &out_write, NULL, 0)) return 0;
	HPCON console;
	if (CreatePseudoConsole((COORD){ 80, 25 }, in_read, out_write, 0, &console) != S_OK) return 0;
	CloseHandle(in_read);
	CloseHandle(out_write);
	SIZE_T room = 0;
	InitializeProcThreadAttributeList(NULL, 1, 0, &room);
	STARTUPINFOEXA start = { .StartupInfo.cb = sizeof start };
	start.lpAttributeList = malloc(room);
	int ok = start.lpAttributeList && InitializeProcThreadAttributeList(start.lpAttributeList, 1, 0, &room) &&
	         UpdateProcThreadAttribute(start.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, console,
	                                   sizeof console, NULL, NULL);
	char line[8192];
	snprintf(line, sizeof line, "\"%s\" --child line", test_self());
	PROCESS_INFORMATION info;
	ok = ok && CreateProcessA(test_self(), line, NULL, NULL, FALSE, EXTENDED_STARTUPINFO_PRESENT, NULL, NULL,
	                          &start.StartupInfo, &info);
	if (ok) {
		CloseHandle(info.hThread);
		/* The console draws its screen around the line, so the line is
		   looked for in what arrives. A console's stdin gives a byte once
		   its line ends. */
		test_child c = { .process = info.hProcess, .release = in_write, .err = NULL };
		size_t got = 0;
		static char text[1 << 16];
		long n;
		while (!strstr(text, "a line") && (n = test_read(out_read, text + got, sizeof text - 1 - got, 5000)) > 0) {
			got += (size_t)n;
			text[got] = 0;
		}
		ok = strstr(text, "a line") != NULL;
		ok &= test_write(in_write, "g\r", 2) == 2;
		DWORD code = 1;
		ok &= WaitForSingleObject(c.process, 10000) == WAIT_OBJECT_0 && GetExitCodeProcess(c.process, &code) && code == 0;
		CloseHandle(c.process);
	}
	CloseHandle(out_read);
	ClosePseudoConsole(console);
	CloseHandle(in_write);
	if (start.lpAttributeList) DeleteProcThreadAttributeList(start.lpAttributeList);
	free(start.lpAttributeList);
	return ok;
}
#else
static int on_terminal(void) {
	int master = posix_openpt(O_RDWR | O_NOCTTY);
	if (master < 0 || grantpt(master) != 0 || unlockpt(master) != 0) return 0;
	int slave = open(ptsname(master), O_RDWR | O_NOCTTY);
	if (slave < 0) return 0;
	test_child c;
	int started = child_start(&c, "line", "", CHILD_TO, slave);
	close(slave);
	/* "a line\n", with the terminal's carriage return. */
	int ok = started && arrived(&c, master, 8, NULL);
	close(master);
	return ok;
}
#endif

void zane_main(void) {
	if (zane_argc >= 2 && strcmp(zane_argv[0], "--child") == 0) run_child();
	int all = 1;
	for (int i = 0; i < 20; i++) all &= child_stops("overflow-printing", "", CHILD_NULL, TEST_NO_FD, 1, full);
	check(all);
	check(overflow_into_full_pipe());
	check(overflow_after_fork());
	check(child_stops("closed", "", CHILD_CLOSED, TEST_NO_FD, 1, ""));
	check(on_terminal());
	check(on_pipe("small", 0));
	check(on_pipe("full", 1));
}
