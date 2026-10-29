#include <pthread.h>
#include "api.h"

double apply(double (*f)(double), double x) { return f(x); }

int64_t sum_each(int64_t (*f)(int64_t), int64_t n) {
	int64_t total = 0;
	for (int64_t i = 1; i <= n; i++) total += f(i);
	return total;
}

int32_t count_if(bool (*p)(int32_t), int32_t n) {
	int32_t count = 0;
	for (int32_t i = 0; i < n; i++)
		if (p(i)) count++;
	return count;
}

point map_point(point (*f)(point), point p) { return f(f(p)); }

void each(void (*f)(int64_t), int64_t n) {
	for (int64_t i = 0; i < n; i++) f(i);
}

typedef struct {
	int64_t (*f)(int64_t);
	int64_t x;
	int64_t out;
} job;

static void *run(void *at) {
	job *j = at;
	j->out = j->f(j->x);
	return NULL;
}

int64_t on_threads(int64_t (*f)(int64_t), int64_t x) {
	enum { N = 4 };
	pthread_t threads[N];
	job jobs[N];
	for (int i = 0; i < N; i++) {
		jobs[i] = (job){ f, x + i, 0 };
		pthread_create(&threads[i], NULL, run, &jobs[i]);
	}
	int64_t total = 0;
	for (int i = 0; i < N; i++) {
		pthread_join(threads[i], NULL);
		total += jobs[i].out;
	}
	return total;
}

int64_t sorted(bool (*before)(int64_t, int64_t), const int64_t *xs) {
	int64_t ys[4];
	for (int i = 0; i < 4; i++) {
		int j = i;
		for (; j > 0 && before(xs[i], ys[j - 1]); j--) ys[j] = ys[j - 1];
		ys[j] = xs[i];
	}
	int64_t digits = 0;
	for (int i = 0; i < 4; i++) digits = digits * 10 + ys[i];
	return digits;
}
