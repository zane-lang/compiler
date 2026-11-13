/* Round 7: leave the machine's free memory with almost no free 2 MiB
   blocks, as a machine that has run a while may, so that a huge page must
   first be made by compaction. It maps all but `spare` MiB of what
   /proc/meminfo calls available, in 4 KiB pages, touches every page, then
   gives back all but one page in `keep`, which leaves the pages it holds
   scattered over physical memory (with `keep` 64, a 2 MiB block holds 8 on
   average, and almost none is free). It prints `fragmented` and holds them
   until it is killed.

   cc -O2 -o fragment fragment.c && ./fragment [keep] [spare MiB] */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

int main(int argc, char **argv) {
	size_t keep = argc > 1 ? strtoul(argv[1], NULL, 10) : 64;
	size_t spare = (argc > 2 ? strtoul(argv[2], NULL, 10) : 1024) << 20;
	size_t avail = 0;
	char line[256];
	FILE *f = fopen("/proc/meminfo", "r");
	while (f && fgets(line, sizeof line, f))
		if (sscanf(line, "MemAvailable: %zu kB", &avail) == 1) break;
	if (f) fclose(f);
	avail <<= 10;
	if (avail <= spare) return 1;
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
	printf("fragmented %zu MiB, %zu MiB held\n", bytes >> 20, (bytes / keep) >> 20);
	fflush(stdout);
	pause();
	return 0;
}
