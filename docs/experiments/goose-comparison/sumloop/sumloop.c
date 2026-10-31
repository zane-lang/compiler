/* A loop whose body is one load and one add: N integers summed 200000
   times, the total written into the first after each round. N is argv[1]. */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

int main(int argc, char **argv) {
	int64_t size = argc > 1 ? atoll(argv[1]) : 2000, rounds = 200000;
	int64_t n = 0, cap = 0, *list = NULL;
	for (int64_t i = 1; i <= size; i++) {
		if (n == cap) { cap = cap ? cap * 2 : 8; list = realloc(list, cap * sizeof *list); }
		list[n++] = i;
	}
	int64_t total = 0;
	for (int64_t r = 0; r < rounds; r++) {
		for (int64_t k = 0; k < n; k++) total += list[k];
		list[0] = total;
	}
	printf("%lld %lld\n", (long long)size, (long long)total);
	return 0;
}
