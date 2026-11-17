/* What a first-touch page fault costs here, against populating the same
   pages with one MADV_POPULATE_WRITE: maps CHUNKS 1 MiB chunks, touches one
   byte per 4 KiB page, and prints ns per page for each way.
   cc -O2 faultcost.c -o faultcost && ./faultcost */
#include <stdio.h>
#include <sys/mman.h>
#include <time.h>
#ifndef MADV_POPULATE_WRITE
#define MADV_POPULATE_WRITE 23
#endif
enum { CHUNK = 1 << 20, CHUNKS = 256, PAGE = 4096 };

static double now(void) {
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec * 1e9 + t.tv_nsec;
}

static double run(int populate) {
	char *m = mmap(NULL, (size_t)CHUNK * CHUNKS, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	madvise(m, (size_t)CHUNK * CHUNKS, MADV_NOHUGEPAGE);
	double t = now();
	for (int c = 0; c < CHUNKS; c++) {
		char *chunk = m + (size_t)c * CHUNK;
		if (populate && madvise(chunk, CHUNK, MADV_POPULATE_WRITE)) perror("madvise");
		for (int p = 0; p < CHUNK; p += PAGE) chunk[p] = 1;
	}
	t = now() - t;
	munmap(m, (size_t)CHUNK * CHUNKS);
	return t / (CHUNKS * (CHUNK / PAGE));
}

int main(void) {
	for (int i = 0; i < 3; i++) printf("fault %.0f ns/page   populate %.0f ns/page\n", run(0), run(1));
	return 0;
}
