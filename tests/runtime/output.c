/* The program's output buffer, tested in C on its own
   (docs/design/lowering.md §9): what a print writes reaches stdout at the
   points stdio's buffer would send it, and a stop from the fault handler
   flushes it with nothing that can deadlock or block. Each case runs in a
   child, which an alarm stops if it hangs, and prints `yes` when it held. */

#include "walks.h"

#include <fcntl.h>
#include <poll.h>
#include <sys/stat.h>
#include <sys/wait.h>

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

/* Everything readable from `fd` until its writers close it, up to `room`
   bytes. */
static size_t drain(int fd, char *text, size_t room) {
	size_t used = 0;
	ssize_t n;
	while (used < room - 1 && (n = read(fd, text + used, room - 1 - used)) > 0) used += (size_t)n;
	text[used] = 0;
	return used;
}

/* A child's status, and whether its stderr was `expected`. */
static int ended(pid_t child, int err, int status, const char *expected) {
	char text[256];
	drain(err, text, sizeof text);
	close(err);
	int got;
	return child > 0 && waitpid(child, &got, 0) == child && WIFEXITED(got) &&
	       WEXITSTATUS(got) == status && strcmp(text, expected) == 0;
}

static const char *const full = "recursion too deep: the machine stack is full\n";

/* The stack overflows in one thread while another prints, and the
   overflowing thread prints at every call. */
static int overflow_while_printing(void) {
	int err[2];
	if (pipe(err) != 0) return 0;
	fflush(stdout);
	pid_t child = fork();
	if (child == 0) {
		close(err[0]);
		int null = open("/dev/null", O_WRONLY);
		if (null < 0 || dup2(null, STDOUT_FILENO) < 0 || dup2(err[1], STDERR_FILENO) < 0) _exit(2);
		alarm(10);
		zane_set_threads(1);
		spawned s = { 0 };
		zane_spawn((char *)&s.result, chatter, NULL, NULL, 0);
		deep(0);
		_exit(2);
	}
	close(err[1]);
	return ended(child, err[0], 1, full);
}

/* The stack overflows while stdout is a pipe that is full and that nothing
   reads: the buffered output is dropped, and the program still stops. */
static int overflow_into_full_pipe(void) {
	int out[2], err[2];
	if (pipe(out) != 0 || pipe(err) != 0) return 0;
	int flags = fcntl(out[1], F_GETFL);
	fcntl(out[1], F_SETFL, flags | O_NONBLOCK);
	char block[4096];
	memset(block, 'x', sizeof block);
	while (write(out[1], block, sizeof block) > 0) {}
	fcntl(out[1], F_SETFL, flags);
	fflush(stdout);
	pid_t child = fork();
	if (child == 0) {
		close(out[0]);
		close(err[0]);
		if (dup2(out[1], STDOUT_FILENO) < 0 || dup2(err[1], STDERR_FILENO) < 0) _exit(2);
		alarm(10);
		say("lost\n");
		deep(0);
		_exit(2);
	}
	close(out[1]);
	close(err[1]);
	int ok = ended(child, err[0], 1, full);
	close(out[0]);
	return ok;
}

/* A write error on stdout, closed, is the program's failure. */
static int closed_stdout(void) {
	fflush(stdout);
	pid_t child = fork();
	if (child == 0) {
		close(STDOUT_FILENO);
		say("nowhere\n");
		return 0;
	}
	int status;
	return child > 0 && waitpid(child, &status, 0) == child && WIFEXITED(status) &&
	       WEXITSTATUS(status) == 1;
}

/* What a child run as `mode` prints and when, read from `out` while the
   child waits for `release`. */
static void child(const char *mode) {
	struct stat s;
	size_t size = fstat(STDOUT_FILENO, &s) == 0 && s.st_blksize > 0 ? (size_t)s.st_blksize : BUFSIZ;
	if (strcmp(mode, "line") == 0) {
		say("a line\n");
	} else {
		char *text = malloc(size + 1);
		memset(text, 'y', size);
		text[size] = 0;
		say(strcmp(mode, "small") == 0 ? "small\n" : text);
		free(text);
	}
	char go;
	if (read(3, &go, 1) != 1) _exit(2);
}

/* Runs this program as a child in `mode`, its stdout `out`, and reports
   whether `expected` bytes reached `reader` while the child waited: 0 for
   none. */
static int arrives(const char *mode, int out, int reader, size_t expected) {
	int release[2];
	if (pipe(release) != 0) return 0;
	fflush(stdout);
	pid_t pid = fork();
	if (pid == 0) {
		alarm(10);
		if (dup2(out, STDOUT_FILENO) < 0 || dup2(release[0], 3) < 0) _exit(2);
		char self[] = "/proc/self/exe";
		char *argv[] = { self, (char *)mode, NULL };
		execv(self, argv);
		_exit(2);
	}
	close(out);
	close(release[0]);
	size_t got = 0;
	char text[1 << 16];
	struct pollfd p = { .fd = reader, .events = POLLIN };
	while (got < expected || expected == 0) {
		if (poll(&p, 1, expected ? 5000 : 300) <= 0) break;
		ssize_t n = read(reader, text + got, sizeof text - got);
		if (n <= 0) break;
		got += (size_t)n;
	}
	int ok = expected ? got >= expected : got == 0;
	if (write(release[1], "g", 1) != 1) ok = 0;
	close(release[1]);
	int status;
	ok &= waitpid(pid, &status, 0) == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0;
	close(reader);
	return ok;
}

static int on_terminal(void) {
	int master = posix_openpt(O_RDWR | O_NOCTTY);
	if (master < 0 || grantpt(master) != 0 || unlockpt(master) != 0) return 0;
	int slave = open(ptsname(master), O_RDWR | O_NOCTTY);
	if (slave < 0) return 0;
	/* "a line\n", with the terminal's carriage return. */
	return arrives("line", slave, master, 8);
}

static int on_pipe(const char *mode, int full_buffer) {
	int out[2];
	if (pipe(out) != 0) return 0;
	struct stat s;
	size_t size = fstat(out[1], &s) == 0 && s.st_blksize > 0 ? (size_t)s.st_blksize : BUFSIZ;
	return arrives(mode, out[1], out[0], full_buffer ? size : 0);
}

void zane_main(void) {
	if (zane_argc == 1) {
		child(zane_argv[0]);
		return;
	}
	int all = 1;
	for (int i = 0; i < 20; i++) all &= overflow_while_printing();
	check(all);
	check(overflow_into_full_pipe());
	check(closed_stdout());
	check(on_terminal());
	check(on_pipe("small", 0));
	check(on_pipe("full", 1));
}
