/* What the runtime's C tests ask of the system, the same on Linux, macOS
   and Windows: a case run in a child process of its own, pipes to talk to
   it, and the memory the process holds. A child is this test's own
   program run again with `--child NAME ARG`, so it starts the way a
   program does; `child_case` picks the case out in `zane_main`. */

#ifndef ZANE_TEST_SYSTEM_H
#define ZANE_TEST_SYSTEM_H

#include "zane_internal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#include <psapi.h>
typedef HANDLE test_fd;
#define TEST_NO_FD NULL
#else
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#include <mach/mach.h>
#endif
typedef int test_fd;
#define TEST_NO_FD (-1)
extern char **environ;
#endif

/* Whether this run is the child for case `name`, and its argument. */
static inline int child_case(const char *name) {
	return zane_argc >= 2 && strcmp(zane_argv[0], "--child") == 0 && strcmp(zane_argv[1], name) == 0;
}

static inline const char *child_arg(void) { return zane_argc >= 3 ? zane_argv[2] : ""; }

/* A pipe: `ends[0]` reads what `ends[1]` writes. Neither is inherited by a
   child unless it is given to one. */
static inline int test_pipe(test_fd ends[2]) {
#ifdef _WIN32
	return CreatePipe(&ends[0], &ends[1], NULL, 0) ? 0 : -1;
#else
	if (pipe(ends) != 0) return -1;
	fcntl(ends[0], F_SETFD, FD_CLOEXEC);
	fcntl(ends[1], F_SETFD, FD_CLOEXEC);
	return 0;
#endif
}

static inline void test_close(test_fd fd) {
#ifdef _WIN32
	if (fd) CloseHandle(fd);
#else
	if (fd >= 0) close(fd);
#endif
}

static inline long test_write(test_fd fd, const void *bytes, size_t n) {
#ifdef _WIN32
	DWORD written;
	return WriteFile(fd, bytes, (DWORD)n, &written, NULL) ? (long)written : -1;
#else
	return (long)write(fd, bytes, n);
#endif
}

/* Up to `room` bytes from `fd`, waiting at most `ms` milliseconds for the
   first: 0 at its end or when nothing came in time, -1 on an error. */
static inline long test_read(test_fd fd, char *bytes, size_t room, int ms) {
#ifdef _WIN32
	DWORD ready = 0;
	for (int waited = 0;; waited += 10) {
		if (!PeekNamedPipe(fd, NULL, 0, NULL, &ready, NULL)) return GetLastError() == ERROR_BROKEN_PIPE ? 0 : -1;
		if (ready > 0 || waited >= ms) break;
		Sleep(10);
	}
	if (ready == 0) return 0;
	DWORD got;
	if (!ReadFile(fd, bytes, ready < room ? ready : (DWORD)room, &got, NULL)) return -1;
	return (long)got;
#else
	struct pollfd p = { .fd = fd, .events = POLLIN };
	if (poll(&p, 1, ms) <= 0) return 0;
	return (long)read(fd, bytes, room);
#endif
}

/* Everything readable from `fd` until its writers close it, up to `room`
   bytes, as a string. */
static inline size_t test_drain(test_fd fd, char *text, size_t room) {
	size_t used = 0;
	long n;
	while (used < room - 1 && (n = test_read(fd, text + used, room - 1 - used, 10000)) > 0) used += (size_t)n;
	text[used] = 0;
	return used;
}

/* The path of this test's own program. */
static inline const char *test_self(void) {
	static char self[4096];
#ifdef _WIN32
	if (!GetModuleFileNameA(NULL, self, sizeof self)) return NULL;
#elif defined(__APPLE__)
	uint32_t room = sizeof self;
	if (_NSGetExecutablePath(self, &room) != 0) return NULL;
#else
	ssize_t n = readlink("/proc/self/exe", self, sizeof self - 1);
	if (n <= 0) return NULL;
	self[n] = 0;
#endif
	return self;
}

/* How a child's stdout is set: to nothing, closed, or to a descriptor. */
enum { CHILD_NULL, CHILD_CLOSED, CHILD_TO };

/* A child running a case: its stdin, through which the parent releases
   it, and its stderr, which the parent reads. */
typedef struct {
#ifdef _WIN32
	HANDLE process;
#else
	pid_t pid;
#endif
	test_fd release, err;
} test_child;

/* Starts case `name` with argument `arg` in a child, its stdout as `out`
   says (to `to` for CHILD_TO). 0 when it could not start. */
static inline int child_start(test_child *c, const char *name, const char *arg, int out, test_fd to) {
	const char *self = test_self();
	test_fd in[2], err[2];
	if (!self || test_pipe(in) != 0) return 0;
	if (test_pipe(err) != 0) {
		test_close(in[0]);
		test_close(in[1]);
		return 0;
	}
	fflush(stdout);
	fflush(stderr);
	int started;
#ifdef _WIN32
	HANDLE child_out = NULL, opened = NULL;
	if (out == CHILD_NULL) {
		SECURITY_ATTRIBUTES inherit = { sizeof inherit, NULL, TRUE };
		opened = CreateFileA("NUL", GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, &inherit, OPEN_EXISTING, 0, NULL);
		child_out = opened;
	} else if (out == CHILD_TO) {
		child_out = to;
	}
	SetHandleInformation(in[0], HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
	SetHandleInformation(err[1], HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
	if (child_out) SetHandleInformation(child_out, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
	char line[8192];
	snprintf(line, sizeof line, "\"%s\" --child %s %s", self, name, arg ? arg : "");
	STARTUPINFOA start = { .cb = sizeof start, .dwFlags = STARTF_USESTDHANDLES };
	start.hStdInput = in[0];
	start.hStdOutput = child_out;
	start.hStdError = err[1];
	PROCESS_INFORMATION info;
	started = CreateProcessA(self, line, NULL, NULL, TRUE, 0, NULL, NULL, &start, &info) != 0;
	if (child_out) SetHandleInformation(child_out, HANDLE_FLAG_INHERIT, 0);
	if (opened) CloseHandle(opened);
	if (started) {
		CloseHandle(info.hThread);
		c->process = info.hProcess;
	}
#else
	posix_spawn_file_actions_t actions;
	posix_spawn_file_actions_init(&actions);
	posix_spawn_file_actions_adddup2(&actions, in[0], 0);
	posix_spawn_file_actions_adddup2(&actions, err[1], 2);
	if (out == CHILD_NULL) posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0);
	else if (out == CHILD_CLOSED) posix_spawn_file_actions_addclose(&actions, 1);
	else posix_spawn_file_actions_adddup2(&actions, to, 1);
	char *argv[] = { (char *)self, "--child", (char *)name, (char *)(arg ? arg : ""), NULL };
	started = posix_spawn(&c->pid, self, &actions, NULL, argv, environ) == 0;
	posix_spawn_file_actions_destroy(&actions);
#endif
	test_close(in[0]);
	test_close(err[1]);
	if (!started) {
		test_close(in[1]);
		test_close(err[0]);
		return 0;
	}
	c->release = in[1];
	c->err = err[0];
	return 1;
}

/* Releases a child waiting on its stdin. */
static inline int child_release(test_child *c) { return test_write(c->release, "g", 1) == 1; }

/* Whether the child exited with `status` within `seconds`; one that is
   still running then is stopped, and has not. Its stderr is read first,
   into `text`, `room` bytes at most. */
static inline int child_ended(test_child *c, int status, char *text, size_t room, int seconds) {
	test_drain(c->err, text, room);
	test_close(c->err);
	test_close(c->release);
#ifdef _WIN32
	DWORD code = 0;
	int exited = WaitForSingleObject(c->process, (DWORD)seconds * 1000) == WAIT_OBJECT_0 &&
	             GetExitCodeProcess(c->process, &code);
	if (!exited) TerminateProcess(c->process, 2);
	CloseHandle(c->process);
	return exited && (int)code == status;
#else
	int got = 0;
	for (int waited = 0;; waited += 10) {
		pid_t done = waitpid(c->pid, &got, WNOHANG);
		if (done == c->pid) break;
		if (done < 0) return 0;
		if (waited >= seconds * 1000) {
			kill(c->pid, SIGKILL);
			waitpid(c->pid, &got, 0);
			return 0;
		}
		struct timespec tick = { 0, 10 * 1000 * 1000 };
		nanosleep(&tick, NULL);
	}
	return WIFEXITED(got) && WEXITSTATUS(got) == status;
#endif
}

/* Whether case `name` with `arg`, its stdout as `out` says, ends with
   `status` and with `expected` on its stderr, within ten seconds. When it
   does not, how it ended goes to this test's stderr, beside the `no`. */
static inline int child_stops(const char *name, const char *arg, int out, test_fd to, int status, const char *expected) {
	test_child c;
	if (!child_start(&c, name, arg, out, to)) {
		fprintf(stderr, "%s: the child did not start\n", name);
		return 0;
	}
	char text[512];
	int ok = child_ended(&c, status, text, sizeof text, 10);
	if (ok && strcmp(text, expected) == 0) return 1;
	fprintf(stderr, "%s: the child %s, its stderr \"%s\"\n", name, ok ? "ended as expected" : "did not end as expected", text);
	return 0;
}

/* What the process holds in memory, in bytes. */
static inline int64_t test_resident(void) {
#ifdef _WIN32
	PROCESS_MEMORY_COUNTERS counters = { .cb = sizeof counters };
	return K32GetProcessMemoryInfo(GetCurrentProcess(), &counters, sizeof counters) ? (int64_t)counters.WorkingSetSize : 0;
#elif defined(__APPLE__)
	mach_task_basic_info_data_t info;
	mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
	if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
	return (int64_t)info.resident_size;
#else
	FILE *f = fopen("/proc/self/statm", "r");
	long size = 0, pages = 0;
	if (f) {
		if (fscanf(f, "%ld %ld", &size, &pages) != 2) pages = 0;
		fclose(f);
	}
	return (int64_t)pages * (int64_t)zane_page_bytes();
#endif
}

#endif
