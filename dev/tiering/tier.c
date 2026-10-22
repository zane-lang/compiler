// Tier-up for an experimental tiered build: waits for the optimized shared
// object named by ZANE_TIER_UP, loads it, and points each slot of this
// program's table at the body tier 1 defines under the same key.
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <stdint.h>

struct entry { const char *key; void *p; };
struct table { int64_t count; struct entry e[]; };
extern struct table __zane_tier_slots __attribute__((weak));

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }

static void *up(void *arg) {
    const char *path = arg;
    double t0 = now();
    struct stat st;
    while (stat(path, &st) != 0) { struct timespec d = {0, 1000000}; nanosleep(&d, 0); }
    void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!h) { fprintf(stderr, "tier: %s\n", dlerror()); return 0; }
    struct table *defs = dlsym(h, "__zane_tier_defs");
    if (!defs) return 0;
    int64_t patched = 0;
    for (int64_t i = 0; i < __zane_tier_slots.count; i++)
        for (int64_t j = 0; j < defs->count; j++)
            if (strcmp(__zane_tier_slots.e[i].key, defs->e[j].key) == 0) {
                __atomic_store_n((void **)__zane_tier_slots.e[i].p, defs->e[j].p, __ATOMIC_RELEASE);
                patched++;
                break;
            }
    if (getenv("ZANE_TIER_LOG"))
        fprintf(stderr, "tier: %lld of %lld slots after %.0f ms\n", (long long)patched,
                (long long)__zane_tier_slots.count, (now() - t0) * 1000);
    return 0;
}

__attribute__((constructor)) static void start(void) {
    const char *path = getenv("ZANE_TIER_UP");
    if (!path || !&__zane_tier_slots) return;
    pthread_t t;
    pthread_create(&t, 0, up, (void *)path);
    pthread_detach(t);
}
