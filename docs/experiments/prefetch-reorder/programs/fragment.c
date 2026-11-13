/* Round 7: leave the machine's free memory with almost no free 2 MiB
   blocks, as a machine that has run a while may, so that a huge page must
   first be made by compaction. It maps all but `spare` MiB of what
   /proc/meminfo calls available, in 4 KiB pages, touches every page, then
   gives back all but one page in `keep`, which leaves the pages it holds
   scattered over physical memory (with `keep` 64, a 2 MiB block holds 8 on
   average, and almost none is free). It prints `fragmented` and holds them
   until it is killed.

   The process may hold no more than `most` MiB at once (a cgroup holds the
   session's to about 13.3 GiB), which can leave whole 2 MiB blocks free
   outside what it touched. So once it has given its pages back, it takes
   those with huge pages, a 2 MiB block at a time, until /proc/buddyinfo
   counts fewer than 16 free blocks of 2 MiB or more, and holds them too.

   cc -O2 -o fragment fragment.c && ./fragment [keep] [spare MiB] [most MiB] */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

/* The free blocks of 2 MiB or more, in 2 MiB blocks. */
static size_t free_huge(void) {
	char line[512];
	size_t total = 0;
	FILE *f = fopen("/proc/buddyinfo", "r");
	while (f && fgets(line, sizeof line, f)) {
		char *at = strstr(line, "zone");
		if (!at) continue;
		at += 4;
		while (*at == ' ') at++;
		while (*at && *at != ' ') at++;
		for (int order = 0; order <= 10; order++) {
			unsigned long n = strtoul(at, &at, 10);
			if (order >= 9) total += n << (order - 9);
		}
	}
	if (f) fclose(f);
	return total;
}

int main(int argc, char **argv) {
	size_t keep = argc > 1 ? strtoul(argv[1], NULL, 10) : 64;
	size_t spare = (argc > 2 ? strtoul(argv[2], NULL, 10) : 1024) << 20;
	size_t most = (argc > 3 ? strtoul(argv[3], NULL, 10) : 12288) << 20;
	size_t avail = 0;
	char line[256];
	FILE *f = fopen("/proc/meminfo", "r");
	while (f && fgets(line, sizeof line, f))
		if (sscanf(line, "MemAvailable: %zu kB", &avail) == 1) break;
	if (f) fclose(f);
	avail <<= 10;
	if (avail <= spare) return 1;
	if (avail - spare > most) avail = most + spare;
	size_t page = (size_t)sysconf(_SC_PAGESIZE), bytes = (avail - spare) / page * page;
	char *at = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (at == MAP_FAILED) return 1;
	madvise(at, bytes, MADV_NOHUGEPAGE);
	for (size_t i = 0; i < bytes; i += page) at[i] = 1;
	for (size_t i = 0; i + page < bytes; i += keep * page) {
		size_t n = (keep - 1) * page;
		if (i + page + n > bytes) n = bytes - i - page;
		madvise(at + i + page, n, MADV_DONTNEED);
	}
	size_t huge = (size_t)2 << 20, cap = (size_t)8 << 30, taken = 0;
	char *raw = mmap(NULL, cap + huge, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
	if (raw == MAP_FAILED) return 1;
	char *ballast = (char *)(((unsigned long)raw + huge - 1) & ~(huge - 1));
	madvise(ballast, cap, MADV_HUGEPAGE);
	while (taken < cap && free_huge() >= 16) {
		ballast[taken] = 1;
		taken += huge;
	}
	if (free_huge() >= 16) {
		fprintf(stderr, "fragment: %zu MiB of huge pages taken and %zu free 2 MiB blocks left\n", taken >> 20,
		        free_huge());
		return 1;
	}
	printf("fragmented %zu MiB, %zu MiB held, %zu MiB of free 2 MiB blocks taken, %zu left\n", bytes >> 20,
	       (bytes / keep) >> 20, taken >> 20, free_huge());
	fflush(stdout);
	pause();
	return 0;
}
