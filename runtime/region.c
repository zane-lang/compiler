#include "zane_internal.h"

/* ---------------------------------------------------------------------- */
/* Each context's range of frames (memory.md §3.1, docs/design/lowering.md §9) */
/* ---------------------------------------------------------------------- */

/* A context reserves its range once, with no access: reserving costs
   addresses, not memory. The range becomes usable `ZANE_STEP` bytes at a
   time, when the program first touches a part of it that is not yet: the
   access faults, the fault handler makes everything up to that step usable,
   and the access runs again. Usable memory takes RAM only where it is
   touched. So scope entry checks nothing, and neither a system that counts
   every writable mapping against a fixed budget (Linux's strict
   overcommit) nor one that wants pages committed before use (Windows)
   charges the program for what it reserved.

   After the range comes a guard of `ZANE_GUARD` unmapped addresses. A
   frame no larger than the guard always starts below the range's end, so
   one that runs past it faults in the guard, and the handler stops the
   program with an error that names the manifest field that sets the
   range's size.

   The program's calls nest on the machine stack as well, and for most
   programs that stack, a few MiB that the system sizes, fills long before
   the range does. The handler stops a program that overflows it with an
   error too, rather than letting it crash. Any other fault is passed on as
   if the handler were not there. */

#ifdef _WIN32
#include <windows.h>
#else
#include <signal.h>
#include <sys/mman.h>
#endif

/* `bytes` of addresses with no access, or null. */
static char *zane_reserve_addresses(size_t bytes) {
#ifdef _WIN32
	return VirtualAlloc(NULL, bytes, MEM_RESERVE, PAGE_NOACCESS);
#else
	void *at = mmap(NULL, bytes, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
	return at == MAP_FAILED ? NULL : at;
#endif
}

/* `size` bytes of the range, and its guard, at a 1 MiB boundary, so each
   MiB of it is the context's alone in the chunk map. The reservation is
   1 MiB larger to find one. A POSIX system gives back what is left over at
   either end; Windows releases a reservation only whole, so there it stays
   reserved and unused. */
void zane_reserve(zane_context *c, int64_t size) {
	size_t total = (size_t)size + ZANE_GUARD;
	char *raw = zane_reserve_addresses(total + ZANE_CHUNK);
	if (!raw) zane_broken("out of addresses for a context's frames");
	char *base = (char *)(((uintptr_t)raw + ZANE_CHUNK - 1) / ZANE_CHUNK * ZANE_CHUNK);
#ifndef _WIN32
	if (base > raw) munmap(raw, (size_t)(base - raw));
	char *end = raw + total + ZANE_CHUNK;
	if (end > base + total) munmap(base + total, (size_t)(end - (base + total)));
#endif
	c->base = c->frontier = c->committed = base;
	c->limit = base + size;
	c->size = size;
	c->top = NULL;
}

/* Everything from what is usable up to the step that holds `at` is made
   usable. Two threads may do this at once for one context -- a spawned
   call writing to a slot of the context that spawned it -- and making a
   page usable twice is harmless, so the larger end is kept. An access below
   what is usable faulted while another thread was making it so, and can
   run again. */
static int zane_commit(zane_context *c, char *at) {
	char *from = __atomic_load_n(&c->committed, __ATOMIC_ACQUIRE);
	if (at < from) return 1;
	size_t steps = (size_t)(at - c->base) / ZANE_STEP + 1;
	char *to = c->base + steps * ZANE_STEP;
	if (to > c->limit) to = c->limit;
#ifdef _WIN32
	if (!VirtualAlloc(from, (size_t)(to - from), MEM_COMMIT, PAGE_READWRITE)) return 0;
#else
	if (mprotect(from, (size_t)(to - from), PROT_READ | PROT_WRITE) != 0) return 0;
#endif
	char *seen = from;
	while (seen < to &&
	       !__atomic_compare_exchange_n(&c->committed, &seen, to, 0, __ATOMIC_RELEASE, __ATOMIC_ACQUIRE))
		;
	return 1;
}

/* The program stops with an error, and status 1, as it does for an index
   out of range: the error is the program's, not the compiler's. It may run
   in the fault handler, so the error is formatted by hand and written with
   one call. */
static char *zane_append(char *at, const char *text) {
	while (*text) *at++ = *text++;
	return at;
}

_Noreturn static void zane_stop(const char *text, char *end) {
	fflush(stdout);
#ifdef _WIN32
	_write(2, text, (unsigned)(end - text));
	ExitProcess(1);
#else
	ssize_t written = write(2, text, (size_t)(end - text));
	(void)written;
	_exit(1);
#endif
}

/* The program's calls nest deeper than its thread's machine stack holds. */
_Noreturn static void zane_stack_full(void) {
	char text[64], *at = zane_append(text, "recursion too deep: the machine stack is full\n");
	zane_stop(text, at);
}

/* The program's scopes nest deeper than its range holds: the error says
   which range is full and the manifest field that sets its size. */
_Noreturn void zane_too_deep_in(zane_context *c) {
	char text[256], digits[24], *at = text;
	int main_context = c->id == 0;
	at = zane_append(at, "scopes nested too deep: ");
	at = zane_append(at, main_context ? "the main context's" : "a spawned call's");
	at = zane_append(at, " fixed-size region of ");
	int64_t mib = c->size / ZANE_CHUNK;
	int n = 0;
	do digits[n++] = (char)('0' + mib % 10); while ((mib /= 10) > 0);
	while (n > 0) *at++ = digits[--n];
	at = zane_append(at, " MiB is full; raise `");
	at = zane_append(at, main_context ? "fixed-region" : "spawned-fixed-region");
	at = zane_append(at, "` in zane.coda\n");
	zane_stop(text, at);
}

/* A frame larger than the guard, which emitted code checks before it
   places it, does not fit. */
void zane_too_deep(void) { zane_too_deep_in(zane_self); }

/* What a fault at `at` is to the runtime: 1 when the access can run again,
   since the step it touched is usable now. One in a guard stops the
   program. Any other is not the runtime's: 0. */
static int zane_fault_at(char *at) {
	uintptr_t *page = zane_page(at, 0);
	uintptr_t entry = page ? __atomic_load_n(page, __ATOMIC_ACQUIRE) : 0;
	if (!(entry & 1)) return 0;
	zane_context *c = (zane_context *)(entry & ~(uintptr_t)1);
	if (at < c->base || at >= c->limit + ZANE_GUARD) return 0;
	if (at >= c->limit) zane_too_deep_in(c);
	return zane_commit(c, at);
}

#ifdef _WIN32

/* Windows raises its own exception for a full machine stack, and leaves the
   handler the room each thread asks for here to run in. */
void zane_thread_start(void) {
	ULONG room = 64 * 1024;
	SetThreadStackGuarantee(&room);
}

static LONG CALLBACK zane_fault(EXCEPTION_POINTERS *e) {
	if (e->ExceptionRecord->ExceptionCode == EXCEPTION_STACK_OVERFLOW) zane_stack_full();
	if (e->ExceptionRecord->ExceptionCode != EXCEPTION_ACCESS_VIOLATION ||
	    e->ExceptionRecord->NumberParameters < 2)
		return EXCEPTION_CONTINUE_SEARCH;
	char *at = (char *)e->ExceptionRecord->ExceptionInformation[1];
	return zane_fault_at(at) ? EXCEPTION_CONTINUE_EXECUTION : EXCEPTION_CONTINUE_SEARCH;
}

void zane_regions_start(void) {
	if (!AddVectoredExceptionHandler(1, zane_fault)) zane_broken("no handler for faults");
}

#else

/* The lowest address of this thread's machine stack, and the stack the
   handler runs on, since a fault from a full machine stack leaves none to
   run on. Each thread that runs the program's code sets both before it
   does. */
static _Thread_local char *zane_stack_low;

enum { ZANE_SIGNAL_STACK = 64 * 1024 };

void zane_thread_start(void) {
	stack_t alternate = { .ss_sp = malloc(ZANE_SIGNAL_STACK), .ss_size = ZANE_SIGNAL_STACK, .ss_flags = 0 };
	if (!alternate.ss_sp || sigaltstack(&alternate, NULL) != 0) zane_broken("no stack for the fault handler");
#ifdef __APPLE__
	pthread_t self = pthread_self();
	zane_stack_low = (char *)pthread_get_stackaddr_np(self) - pthread_get_stacksize_np(self);
#else
	pthread_attr_t attributes;
	void *low;
	size_t size;
	if (pthread_getattr_np(pthread_self(), &attributes) == 0) {
		if (pthread_attr_getstack(&attributes, &low, &size) == 0) zane_stack_low = low;
		pthread_attr_destroy(&attributes);
	}
#endif
}

/* Whether a fault at `at` is past the end of this thread's machine stack:
   in the guard below it, or the last few pages above. */
static int zane_stack_fault(char *at) {
	char *low = zane_stack_low;
	return low && at < low + 64 * 1024 && at + ZANE_CHUNK >= low;
}

/* The handlers that were there before, for the faults that are not the
   runtime's. A protection fault is SIGSEGV on Linux, and SIGBUS on some
   systems, macOS among them. */
static struct sigaction zane_before[2];

static void zane_fault(int signal, siginfo_t *info, void *context) {
	if (zane_fault_at(info->si_addr)) return;
	if (zane_stack_fault(info->si_addr)) zane_stack_full();
	struct sigaction *before = &zane_before[signal == SIGBUS];
	if ((before->sa_flags & SA_SIGINFO) && before->sa_sigaction) {
		before->sa_sigaction(signal, info, context);
	} else if (before->sa_handler != SIG_DFL && before->sa_handler != SIG_IGN) {
		before->sa_handler(signal);
	} else {
		/* The access runs again and faults with the default action. */
		struct sigaction plain = { 0 };
		plain.sa_handler = SIG_DFL;
		sigemptyset(&plain.sa_mask);
		sigaction(signal, &plain, NULL);
	}
}

void zane_regions_start(void) {
	struct sigaction handler = { 0 };
	handler.sa_sigaction = zane_fault;
	handler.sa_flags = SA_SIGINFO | SA_ONSTACK;
	sigemptyset(&handler.sa_mask);
	if (sigaction(SIGSEGV, &handler, &zane_before[0]) != 0 || sigaction(SIGBUS, &handler, &zane_before[1]) != 0)
		zane_broken("no handler for faults");
}

#endif
