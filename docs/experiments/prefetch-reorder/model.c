#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/mman.h>
#include <pthread.h>
#include <sched.h>

#define PF(p) __builtin_prefetch((p), 0, 3)
#define PFW(p) __builtin_prefetch((p), 1, 3)
#define NOINLINE __attribute__((noinline))
#define MAXG 256

static void NOINLINE trap(void) { abort(); }
#define CHECK(i, n) do { if (__builtin_expect((uint64_t)(i) >= (uint64_t)(n), 0)) trap(); } while (0)

static int g_huge;
static void *alloc(size_t bytes) {
  size_t two = 2u << 20, len = bytes + two;
  char *p = mmap(0, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (p == MAP_FAILED) { perror("mmap"); exit(1); }
  char *q = (char *)(((uintptr_t)p + two - 1) & ~(uintptr_t)(two - 1));
  madvise(q, bytes, g_huge ? MADV_HUGEPAGE : MADV_NOHUGEPAGE);
  return q;
}
static uint64_t rs = 0x9E3779B97F4A7C15ULL;
static inline uint64_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return rs; }
static inline uint64_t mix(uint64_t x) {
  x ^= x >> 30; x *= 0xbf58476d1ce4e5b9ULL; x ^= x >> 27; x *= 0x94d049bb133111ebULL; x ^= x >> 31; return x;
}
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e9 + t.tv_nsec; }

static uint64_t n, m;

/* ---------- gather: s += a[idx[i]] ---------- */
static uint64_t *ga; static uint32_t *gidx, *gtmp;
static uint64_t NOINLINE gather_base(int p) { uint64_t s = 0;
  for (uint64_t i = 0; i < m; i++) { uint32_t j = gidx[i]; CHECK(j, n); s += ga[j]; } return s; }
static uint64_t NOINLINE gather_naive(int p) { uint64_t s = 0;
  for (uint64_t i = 0; i < m; i++) { uint32_t j = gidx[i]; PF(&ga[j]); CHECK(j, n); s += ga[j]; } return s; }
static uint64_t NOINLINE gather_ahead(int D) { uint64_t s = 0, i = 0;
  for (; i + D < m; i++) { PF(&ga[gidx[i + D]]); uint32_t j = gidx[i]; CHECK(j, n); s += ga[j]; }
  for (; i < m; i++) { uint32_t j = gidx[i]; CHECK(j, n); s += ga[j]; } return s; }
static uint64_t NOINLINE gather_group(int G) { uint64_t s = 0, i = 0;
  for (; i + G <= m; i += G) {
    for (int k = 0; k < G; k++) PF(&ga[gidx[i + k]]);
    for (int k = 0; k < G; k++) { uint32_t j = gidx[i + k]; CHECK(j, n); s += ga[j]; } }
  for (; i < m; i++) { uint32_t j = gidx[i]; CHECK(j, n); s += ga[j]; } return s; }
static uint64_t NOINLINE gather_sorted(int logB) {
  int shift = logB - 3; uint64_t nb = ((n - 1) >> shift) + 1;
  uint64_t *cnt = calloc(nb + 1, 8);
  for (uint64_t i = 0; i < m; i++) cnt[(gidx[i] >> shift) + 1]++;
  for (uint64_t b = 0; b < nb; b++) cnt[b + 1] += cnt[b];
  for (uint64_t i = 0; i < m; i++) { uint32_t j = gidx[i]; gtmp[cnt[j >> shift]++] = j; }
  free(cnt); uint64_t s = 0;
  for (uint64_t i = 0; i < m; i++) { uint32_t j = gtmp[i]; CHECK(j, n); s += ga[j]; } return s; }

/* ---------- heavy: 64-byte elements, branch on loaded data ---------- */
typedef struct { uint64_t key, w[7]; } E;
static E *ha; static uint64_t hist[16];
static inline uint64_t body(const E *e, uint64_t acc) {
  if (e->key & 1) { uint64_t h = e->w[0]; h ^= h >> 33; h *= 0xff51afd7ed558ccdULL; h ^= h >> 33;
    h *= 0xc4ceb9fe1a85ec53ULL; h ^= h >> 33; h += e->w[1] * e->w[2]; hist[h & 15]++; return acc * 31 + h; }
  return acc ^ (e->w[4] + (e->w[5] >> 3)); }
static uint64_t NOINLINE heavy_base(int p) { uint64_t s = 0;
  for (uint64_t i = 0; i < m; i++) { uint32_t j = gidx[i]; CHECK(j, n); s = body(&ha[j], s); } return s; }
static uint64_t NOINLINE heavy_naive(int p) { uint64_t s = 0;
  for (uint64_t i = 0; i < m; i++) { uint32_t j = gidx[i]; PF(&ha[j]); CHECK(j, n); s = body(&ha[j], s); } return s; }
static uint64_t NOINLINE heavy_ahead(int D) { uint64_t s = 0, i = 0;
  for (; i + D < m; i++) { PF(&ha[gidx[i + D]]); uint32_t j = gidx[i]; CHECK(j, n); s = body(&ha[j], s); }
  for (; i < m; i++) { uint32_t j = gidx[i]; CHECK(j, n); s = body(&ha[j], s); } return s; }
static uint64_t NOINLINE heavy_group(int G) { uint64_t s = 0, i = 0;
  for (; i + G <= m; i += G) {
    for (int k = 0; k < G; k++) PF(&ha[gidx[i + k]]);
    for (int k = 0; k < G; k++) { uint32_t j = gidx[i + k]; CHECK(j, n); s = body(&ha[j], s); } }
  for (; i < m; i++) { uint32_t j = gidx[i]; CHECK(j, n); s = body(&ha[j], s); } return s; }
/* fission: the real load of the branch field happens early, no prefetch instruction */
static uint64_t NOINLINE heavy_earlyload(int G) { uint64_t s = 0, i = 0; uint64_t keys[MAXG];
  for (; i + G <= m; i += G) {
    for (int k = 0; k < G; k++) { uint32_t j = gidx[i + k]; CHECK(j, n); keys[k] = ha[j].key; }
    for (int k = 0; k < G; k++) { const E *e = &ha[gidx[i + k]];
      if (keys[k] & 1) { uint64_t h = e->w[0]; h ^= h >> 33; h *= 0xff51afd7ed558ccdULL; h ^= h >> 33;
        h *= 0xc4ceb9fe1a85ec53ULL; h ^= h >> 33; h += e->w[1] * e->w[2]; hist[h & 15]++; s = s * 31 + h; }
      else s ^= e->w[4] + (e->w[5] >> 3); } }
  for (; i < m; i++) { uint32_t j = gidx[i]; CHECK(j, n); s = body(&ha[j], s); } return s; }

/* ---------- scatter: a[idx[i]] += i|1 ---------- */
static uint64_t NOINLINE scatter_base(int p) {
  for (uint64_t i = 0; i < m; i++) { uint32_t j = gidx[i]; CHECK(j, n); ga[j] += i | 1; } return 0; }
static uint64_t NOINLINE scatter_ahead(int D) { uint64_t i = 0;
  for (; i + D < m; i++) { PFW(&ga[gidx[i + D]]); uint32_t j = gidx[i]; CHECK(j, n); ga[j] += i | 1; }
  for (; i < m; i++) { uint32_t j = gidx[i]; CHECK(j, n); ga[j] += i | 1; } return 0; }
static uint64_t NOINLINE scatter_group(int G) { uint64_t i = 0;
  for (; i + G <= m; i += G) {
    for (int k = 0; k < G; k++) PFW(&ga[gidx[i + k]]);
    for (int k = 0; k < G; k++) { uint32_t j = gidx[i + k]; CHECK(j, n); ga[j] += (i + k) | 1; } }
  for (; i < m; i++) { uint32_t j = gidx[i]; CHECK(j, n); ga[j] += i | 1; } return 0; }

/* ---------- hash probe: open addressing, linear probing ---------- */
typedef struct { uint64_t key, val; } Slot;
static Slot *ht; static uint64_t hmask; static int hshift; static uint64_t *hq;
static inline uint64_t hslot(uint64_t k) { return (k * 0x9E3779B97F4A7C15ULL) >> hshift; }
static inline uint64_t probe(uint64_t k) { uint64_t h = hslot(k);
  for (;;) { Slot *s = &ht[h]; if (s->key == k) return s->val; if (!s->key) return 0; h = (h + 1) & hmask; } }
static uint64_t NOINLINE hash_base(int p) { uint64_t s = 0; for (uint64_t i = 0; i < m; i++) s += probe(hq[i]); return s; }
static uint64_t NOINLINE hash_ahead(int D) { uint64_t s = 0, i = 0;
  for (; i + D < m; i++) { PF(&ht[hslot(hq[i + D])]); s += probe(hq[i]); }
  for (; i < m; i++) s += probe(hq[i]); return s; }
static uint64_t NOINLINE hash_group(int G) { uint64_t s = 0, i = 0;
  for (; i + G <= m; i += G) {
    for (int k = 0; k < G; k++) PF(&ht[hslot(hq[i + k])]);
    for (int k = 0; k < G; k++) s += probe(hq[i + k]); }
  for (; i < m; i++) s += probe(hq[i]); return s; }

/* ---------- binary search over a sorted array ---------- */
static uint64_t *ba, *be;
static uint64_t NOINLINE bs_base(int p) { uint64_t s = 0;
  for (uint64_t i = 0; i < m; i++) { uint64_t key = hq[i], b = 0, len = n;
    while (len > 1) { uint64_t half = len / 2; b += ba[b + half - 1] < key ? half : 0; len -= half; }
    b += ba[b] < key; s += b < n ? ba[b] : 0; } return s; }
static uint64_t NOINLINE bs_bothways(int p) { uint64_t s = 0;
  for (uint64_t i = 0; i < m; i++) { uint64_t key = hq[i], b = 0, len = n;
    while (len > 1) { uint64_t half = len / 2, q = (len - half) / 2;
      PF(&ba[b + q - 1]); PF(&ba[b + half + q - 1]);
      b += ba[b + half - 1] < key ? half : 0; len -= half; }
    b += ba[b] < key; s += b < n ? ba[b] : 0; } return s; }
static uint64_t NOINLINE bs_group(int W) { uint64_t s = 0, i = 0; uint64_t bb[MAXG];
  for (; i + W <= m; i += W) { uint64_t len = n;
    for (int k = 0; k < W; k++) bb[k] = 0;
    while (len > 1) { uint64_t half = len / 2, nl = len - half, nh = nl / 2;
      for (int k = 0; k < W; k++) { uint64_t b = bb[k]; b += ba[b + half - 1] < hq[i + k] ? half : 0; bb[k] = b;
        PF(&ba[b + (nh ? nh - 1 : 0)]); }
      len = nl; }
    for (int k = 0; k < W; k++) { uint64_t b = bb[k]; b += ba[b] < hq[i + k]; s += b < n ? ba[b] : 0; } }
  for (; i < m; i++) { uint64_t key = hq[i], b = 0, len = n;
    while (len > 1) { uint64_t half = len / 2; b += ba[b + half - 1] < key ? half : 0; len -= half; }
    b += ba[b] < key; s += b < n ? ba[b] : 0; } return s; }
static uint64_t NOINLINE bs_eytz(int p) { uint64_t s = 0;
  for (uint64_t i = 0; i < m; i++) { uint64_t key = hq[i], k = 1;
    while (k <= n) { PF(&be[k * 16]); k = 2 * k + (be[k] < key); }
    k >>= __builtin_ffsll(~k); s += k ? be[k] : 0; } return s; }
static uint64_t eytz_fill(uint64_t k, uint64_t i) {
  if (k <= n) { i = eytz_fill(2 * k, i); be[k] = ba[i++]; i = eytz_fill(2 * k + 1, i); } return i; }

/* ---------- tree lookup: nodes at random places, 32-bit handles ---------- */
typedef struct { uint64_t key; uint32_t l, r; } Node;
static Node *tn; static uint32_t troot, *tperm;
static uint32_t tbuild(uint64_t lo, uint64_t hi) {
  if (lo >= hi) return 0; uint64_t mid = (lo + hi) / 2; uint32_t id = tperm[mid];
  tn[id].key = 2 * mid + 1; tn[id].l = tbuild(lo, mid); tn[id].r = tbuild(mid + 1, hi); return id; }
static uint64_t NOINLINE tree_base(int p) { uint64_t s = 0;
  for (uint64_t i = 0; i < m; i++) { uint64_t key = hq[i]; uint32_t c = troot;
    while (c) { Node *d = &tn[c]; if (d->key == key) { s += c; break; } c = key < d->key ? d->l : d->r; } } return s; }
static uint64_t NOINLINE tree_group(int W) { uint64_t s = 0, i = 0; uint32_t cur[MAXG];
  for (; i + W <= m; i += W) { int live = W;
    for (int k = 0; k < W; k++) cur[k] = troot;
    while (live) for (int k = 0; k < W; k++) { uint32_t c = cur[k]; if (!c) continue;
      Node *d = &tn[c]; uint64_t key = hq[i + k];
      if (d->key == key) { s += c; cur[k] = 0; live--; }
      else { c = key < d->key ? d->l : d->r; cur[k] = c; if (c) PF(&tn[c]); else live--; } } }
  for (; i < m; i++) { uint64_t key = hq[i]; uint32_t c = troot;
    while (c) { Node *d = &tn[c]; if (d->key == key) { s += c; break; } c = key < d->key ? d->l : d->r; } } return s; }
static uint64_t NOINLINE tree_amac(int W) { uint64_t s = 0, next = 0; uint64_t keys[MAXG]; uint32_t cur[MAXG]; int live = 0;
  for (int k = 0; k < W; k++) { cur[k] = 0; if (next < m) { keys[k] = hq[next++]; cur[k] = troot; live++; } }
  for (int k = 0; live; k = k + 1 == W ? 0 : k + 1) { uint32_t c = cur[k]; if (!c) continue;
    Node *d = &tn[c]; uint64_t key = keys[k];
    if (d->key == key) { s += c; c = 0; } else { c = key < d->key ? d->l : d->r; if (c) { PF(&tn[c]); cur[k] = c; continue; } }
    if (next < m) { keys[k] = hq[next++]; cur[k] = troot; } else { cur[k] = 0; live--; } }
  return s; }

/* ---------- round 2 ---------- */
static uint64_t NOINLINE heavy_nta(int D) { uint64_t s = 0, i = 0;
  for (; i + D < m; i++) { __builtin_prefetch(&ha[gidx[i + D]], 0, 0); uint32_t j = gidx[i]; CHECK(j, n); s = body(&ha[j], s); }
  for (; i < m; i++) { uint32_t j = gidx[i]; CHECK(j, n); s = body(&ha[j], s); } return s; }

/* a second thread that loads ahead of the first */
static volatile uint64_t prog; static volatile int stop; static int hdist, hkind, hcpu;
static void *helper(void *arg) { uint64_t c = 0, sink = 0;
  cpu_set_t set; CPU_ZERO(&set); CPU_SET(hcpu, &set); pthread_setaffinity_np(pthread_self(), sizeof set, &set);
  while (!stop) { uint64_t p = prog, lim = p + hdist; if (lim > m) lim = m; if (c < p) c = p;
    if (c >= lim) { __builtin_ia32_pause(); continue; }
    if (hkind) for (; c < lim; c++) sink += ha[gidx[c]].key; else for (; c < lim; c++) sink += ga[gidx[c]]; }
  return (void *)sink; }
static uint64_t with_helper(int K, int kind, uint64_t (*fn)(void)) { pthread_t t;
  hdist = K; hkind = kind; prog = 0; stop = 0; pthread_create(&t, 0, helper, 0);
  uint64_t s = fn(); stop = 1; pthread_join(t, 0); return s; }
static uint64_t heavy_pub(void) { uint64_t s = 0;
  for (uint64_t i = 0; i < m; i++) { if (!(i & 15)) prog = i; uint32_t j = gidx[i]; CHECK(j, n); s = body(&ha[j], s); } return s; }
static uint64_t gather_pub(void) { uint64_t s = 0;
  for (uint64_t i = 0; i < m; i++) { if (!(i & 15)) prog = i; uint32_t j = gidx[i]; CHECK(j, n); s += ga[j]; } return s; }
static uint64_t NOINLINE heavy_helper(int K) { return with_helper(K, 1, heavy_pub); }
static uint64_t NOINLINE gather_helper(int K) { return with_helper(K, 0, gather_pub); }

/* two hops: s += a[b[idx[i]]] */
static uint32_t *tb; static uint64_t nb;
static uint64_t NOINLINE two_base(int p) { uint64_t s = 0;
  for (uint64_t i = 0; i < m; i++) { uint32_t j = gidx[i]; CHECK(j, nb); uint32_t k = tb[j]; CHECK(k, n); s += ga[k]; } return s; }
static uint64_t NOINLINE two_ahead(int D) { uint64_t s = 0, i = 0;
  for (; i + D < m; i++) { PF(&tb[gidx[i + D]]); uint32_t j = gidx[i]; CHECK(j, nb); uint32_t k = tb[j]; CHECK(k, n); s += ga[k]; }
  for (; i < m; i++) { uint32_t j = gidx[i]; CHECK(j, nb); uint32_t k = tb[j]; CHECK(k, n); s += ga[k]; } return s; }
static uint64_t NOINLINE two_staged(int D) { uint64_t s = 0, i = 0;
  for (; i + 2 * D < m; i++) { PF(&tb[gidx[i + 2 * D]]); uint32_t e = gidx[i + D]; if (e < nb) PF(&ga[tb[e]]);
    uint32_t j = gidx[i]; CHECK(j, nb); uint32_t k = tb[j]; CHECK(k, n); s += ga[k]; }
  for (; i < m; i++) { uint32_t j = gidx[i]; CHECK(j, nb); uint32_t k = tb[j]; CHECK(k, n); s += ga[k]; } return s; }

/* a list of short lists: handles in order, payloads at random places */
typedef struct { uint64_t *ptr; uint32_t len, cap; } Row;
static Row *rows;
static uint64_t NOINLINE nested_base(int p) { uint64_t s = 0;
  for (uint64_t i = 0; i < m; i++) { Row r = rows[i]; for (uint32_t k = 0; k < r.len; k++) s += r.ptr[k]; } return s; }
static uint64_t NOINLINE nested_ahead(int D) { uint64_t s = 0, i = 0;
  for (; i + D < m; i++) { PF(rows[i + D].ptr); Row r = rows[i]; for (uint32_t k = 0; k < r.len; k++) s += r.ptr[k]; }
  for (; i < m; i++) { Row r = rows[i]; for (uint32_t k = 0; k < r.len; k++) s += r.ptr[k]; } return s; }

/* many short chains: for each list, walk it */
typedef struct { uint64_t val; uint32_t next, pad; } Link;
static Link *ln; static uint32_t *heads;
static uint64_t NOINLINE chains_base(int p) { uint64_t s = 0;
  for (uint64_t i = 0; i < m; i++) for (uint32_t c = heads[i]; c; c = ln[c].next) s += ln[c].val; return s; }
static uint64_t NOINLINE chains_ahead(int D) { uint64_t s = 0, i = 0;
  for (; i + D < m; i++) { PF(&ln[heads[i + D]]); for (uint32_t c = heads[i]; c; c = ln[c].next) s += ln[c].val; }
  for (; i < m; i++) for (uint32_t c = heads[i]; c; c = ln[c].next) s += ln[c].val; return s; }
static uint64_t NOINLINE chains_group(int W) { uint64_t s = 0, i = 0; uint32_t cur[MAXG];
  for (; i + W <= m; i += W) { int live = W;
    for (int k = 0; k < W; k++) { cur[k] = heads[i + k]; PF(&ln[cur[k]]); }
    while (live) for (int k = 0; k < W; k++) { uint32_t c = cur[k]; if (!c) continue;
      s += ln[c].val; c = ln[c].next; cur[k] = c; if (c) PF(&ln[c]); else live--; } }
  for (; i < m; i++) for (uint32_t c = heads[i]; c; c = ln[c].next) s += ln[c].val; return s; }
static uint64_t NOINLINE chains_amac(int W) { uint64_t s = 0, next = 0; uint32_t cur[MAXG]; int live = 0;
  for (int k = 0; k < W; k++) { cur[k] = 0; if (next < m) { cur[k] = heads[next++]; PF(&ln[cur[k]]); live++; } }
  for (int k = 0; live; k = k + 1 == W ? 0 : k + 1) { uint32_t c = cur[k]; if (!c) continue;
    s += ln[c].val; c = ln[c].next;
    if (c) { PF(&ln[c]); cur[k] = c; continue; }
    if (next < m) { cur[k] = heads[next++]; PF(&ln[cur[k]]); } else { cur[k] = 0; live--; } }
  return s; }

/* ---------- round 3: one loop with both kinds of miss ---------- */
/* for each i: load a record at a random place, work on it, look its key up in the tree */
static uint64_t cmask;
static inline uint64_t work(const E *e) {
  if (e->key & 1) { uint64_t h = e->w[0]; h ^= h >> 33; h *= 0xff51afd7ed558ccdULL; h ^= h >> 33;
    h *= 0xc4ceb9fe1a85ec53ULL; h ^= h >> 33; h += e->w[1] * e->w[2]; hist[h & 15]++; return h; }
  return e->w[4] + (e->w[5] >> 3); }
static inline uint32_t walk(uint64_t key) { uint32_t c = troot;
  while (c) { Node *d = &tn[c]; if (d->key == key) break; c = key < d->key ? d->l : d->r; } return c; }
static uint64_t NOINLINE combo_base(int p) { uint64_t s = 0;
  for (uint64_t i = 0; i < m; i++) { uint32_t j = gidx[i]; CHECK(j, n); const E *e = &ha[j]; s += work(e) + walk(e->w[6] & cmask); } return s; }
static uint64_t NOINLINE combo_ahead(int D) { uint64_t s = 0, i = 0;
  for (; i + D < m; i++) { PF(&ha[gidx[i + D]]); uint32_t j = gidx[i]; CHECK(j, n); const E *e = &ha[j]; s += work(e) + walk(e->w[6] & cmask); }
  for (; i < m; i++) { uint32_t j = gidx[i]; CHECK(j, n); const E *e = &ha[j]; s += work(e) + walk(e->w[6] & cmask); } return s; }
/* D = 0: interleave the walks only; D > 0: also prefetch the record D refills ahead */
static inline uint64_t combo_amac(int W, int D) { uint64_t s = 0, next = 0; uint64_t keys[MAXG]; uint32_t cur[MAXG]; int live = 0;
  for (int k = 0; k < W; k++) cur[k] = 0;
  for (int k = 0; k < W && next < m; k++) { uint32_t j = gidx[next++]; CHECK(j, n); const E *e = &ha[j];
    s += work(e); keys[k] = e->w[6] & cmask; cur[k] = troot; live++; }
  for (int k = 0; live; k = k + 1 == W ? 0 : k + 1) { uint32_t c = cur[k]; if (!c) continue;
    Node *d = &tn[c]; uint64_t key = keys[k];
    if (d->key == key) s += c; else { c = key < d->key ? d->l : d->r; if (c) { PF(&tn[c]); cur[k] = c; continue; } }
    if (next < m) { if (D && next + D < m) PF(&ha[gidx[next + D]]);
      uint32_t j = gidx[next++]; CHECK(j, n); const E *e = &ha[j]; s += work(e); keys[k] = e->w[6] & cmask; cur[k] = troot; }
    else { cur[k] = 0; live--; } }
  return s; }
static uint64_t NOINLINE combo_inter(int W) { return combo_amac(W, 0); }
static uint64_t NOINLINE combo_both(int W) { return combo_amac(W, W); }
static uint64_t NOINLINE combo_both32(int W) { return combo_amac(W, 32); }
/* every miss a stage: a refill only prefetches the record, the next visit reads it */
static uint64_t NOINLINE combo_staged(int W) { uint64_t s = 0, next = 0; uint64_t keys[MAXG]; uint32_t cur[MAXG], rec[MAXG]; int live = 0;
  for (int k = 0; k < W; k++) { cur[k] = 0; rec[k] = ~0u; }
  for (int k = 0; k < W && next < m; k++) { uint32_t j = gidx[next++]; CHECK(j, n); PF(&ha[j]); rec[k] = j; cur[k] = 1; live++; }
  for (int k = 0; live; k = k + 1 == W ? 0 : k + 1) { uint32_t c = cur[k]; if (!c) continue;
    if (rec[k] != ~0u) { const E *e = &ha[rec[k]]; s += work(e); keys[k] = e->w[6] & cmask; rec[k] = ~0u; cur[k] = troot; continue; }
    Node *d = &tn[c]; uint64_t key = keys[k];
    if (d->key == key) s += c; else { c = key < d->key ? d->l : d->r; if (c) { PF(&tn[c]); cur[k] = c; continue; } }
    if (next < m) { uint32_t j = gidx[next++]; CHECK(j, n); PF(&ha[j]); rec[k] = j; cur[k] = 1; }
    else { cur[k] = 0; live--; } }
  return s; }

typedef struct { const char *name; uint64_t (*fn)(int); int np; int p[10]; } Variant;
static const char *kname; static int logbytes;
static void run(Variant *v, int nv) {
  for (int i = 0; i < nv; i++) for (int j = 0; j < (v[i].np ? v[i].np : 1); j++) {
    double best = 1e30; uint64_t sum = 0;
    for (int r = 0; r < 3; r++) { double t = now(); sum = v[i].fn(v[i].p[j]); t = now() - t; if (t < best) best = t; }
    printf("%s\t%d\t%d\t%s\t%d\t%.2f\t%016llx\n", kname, logbytes, g_huge, v[i].name, v[i].p[j], best / m, (unsigned long long)sum);
    fflush(stdout); } }
#define RUN(v) run(v, sizeof v / sizeof *v)
#define DS 7, {1, 2, 4, 8, 16, 32, 64}
#define HS 4, {64, 256, 1024, 4096}
#define GS 6, {4, 8, 16, 32, 64, 128}

int main(int argc, char **argv) {
  if (argc < 5) { fprintf(stderr, "model KERNEL LOG2BYTES LOG2OPS HUGE\n"); return 2; }
  kname = argv[1]; hcpu = sched_getcpu() ? sched_getcpu() - 1 : 1; logbytes = atoi(argv[2]); m = 1ull << atoi(argv[3]); g_huge = atoi(argv[4]);
  uint64_t bytes = 1ull << logbytes;
  if (!strcmp(kname, "gather") || !strcmp(kname, "scatter") || !strcmp(kname, "heavy")) {
    int heavy = !strcmp(kname, "heavy"); n = bytes / (heavy ? 64 : 8);
    gidx = alloc(m * 4); gtmp = alloc(m * 4);
    for (uint64_t i = 0; i < m; i++) { gidx[i] = rnd() % n; gtmp[i] = 0; }
    if (heavy) { ha = alloc(bytes); for (uint64_t i = 0; i < n; i++) for (int k = 0; k < 8; k++) (&ha[i].key)[k] = rnd();
      Variant v[] = {{"base", heavy_base}, {"naive", heavy_naive}, {"ahead", heavy_ahead, DS}, {"group", heavy_group, GS}, {"earlyload", heavy_earlyload, GS}, {"nta", heavy_nta, 3, {16, 32, 64}}, {"helper", heavy_helper, HS}}; RUN(v); }
    else { ga = alloc(bytes); for (uint64_t i = 0; i < n; i++) ga[i] = rnd();
      if (!strcmp(kname, "gather")) { Variant v[] = {{"base", gather_base}, {"naive", gather_naive}, {"ahead", gather_ahead, DS}, {"group", gather_group, GS}, {"sorted", gather_sorted, 3, {18, 20, 22}}, {"helper", gather_helper, HS}}; RUN(v); }
      else { Variant v[] = {{"base", scatter_base}, {"ahead", scatter_ahead, DS}, {"group", scatter_group, GS}}; RUN(v); } }
  } else if (!strcmp(kname, "hash")) {
    uint64_t cap = bytes / 16, nk = cap / 2; hmask = cap - 1; hshift = 64 - (logbytes - 4);
    ht = alloc(bytes); memset(ht, 0, bytes);
    for (uint64_t i = 0; i < nk; i++) { uint64_t k = mix(i + 1) | 1, h = hslot(k);
      while (ht[h].key && ht[h].key != k) h = (h + 1) & hmask; ht[h].key = k; ht[h].val = k ^ 0x55; }
    hq = alloc(m * 8);
    for (uint64_t i = 0; i < m; i++) { uint64_t r = rnd(); hq[i] = r & 1 ? mix(r % nk + 1) | 1 : (mix(r) & ~1ull) | 2; }
    Variant v[] = {{"base", hash_base}, {"ahead", hash_ahead, DS}, {"group", hash_group, GS}}; RUN(v);
  } else if (!strcmp(kname, "bsearch")) {
    n = bytes / 8; ba = alloc(bytes); be = alloc(bytes + 4096); hq = alloc(m * 8);
    for (uint64_t i = 0; i < n; i++) ba[i] = 2 * i + 1;
    be[0] = 0; eytz_fill(1, 0);
    for (uint64_t i = 0; i < m; i++) hq[i] = rnd() % (2 * n);
    Variant v[] = {{"base", bs_base}, {"bothways", bs_bothways}, {"group", bs_group, GS}, {"eytzinger", bs_eytz}}; RUN(v);
  } else if (!strcmp(kname, "tree")) {
    n = bytes / 16 - 1; tn = alloc(bytes); tperm = alloc(n * 4); hq = alloc(m * 8);
    for (uint64_t i = 0; i < n; i++) tperm[i] = i + 1;
    for (uint64_t i = n - 1; i > 0; i--) { uint64_t j = rnd() % (i + 1); uint32_t t = tperm[i]; tperm[i] = tperm[j]; tperm[j] = t; }
    troot = tbuild(0, n);
    for (uint64_t i = 0; i < m; i++) hq[i] = rnd() % (2 * n);
    Variant v[] = {{"base", tree_base}, {"group", tree_group, GS}, {"amac", tree_amac, GS}}; RUN(v);
  } else if (!strcmp(kname, "gatherx") || !strcmp(kname, "heavyx")) {
    int heavy = !strcmp(kname, "heavyx"); n = bytes / (heavy ? 64 : 8); gidx = alloc(m * 4);
    for (uint64_t i = 0; i < m; i++) gidx[i] = rnd() % n;
    if (heavy) { ha = alloc(bytes); for (uint64_t i = 0; i < n; i++) for (int k = 0; k < 8; k++) (&ha[i].key)[k] = rnd();
      Variant v[] = {{"base", heavy_base}, {"ahead", heavy_ahead, 2, {16, 32}}}; RUN(v); }
    else { ga = alloc(bytes); for (uint64_t i = 0; i < n; i++) ga[i] = rnd();
      Variant v[] = {{"base", gather_base}, {"ahead", gather_ahead, 2, {16, 32}}}; RUN(v); }
  } else if (!strcmp(kname, "twohop")) {
    nb = bytes / 8; n = bytes / 16; tb = alloc(nb * 4); ga = alloc(n * 8); gidx = alloc(m * 4);
    for (uint64_t i = 0; i < nb; i++) tb[i] = rnd() % n;
    for (uint64_t i = 0; i < n; i++) ga[i] = rnd();
    for (uint64_t i = 0; i < m; i++) gidx[i] = rnd() % nb;
    Variant v[] = {{"base", two_base}, {"ahead", two_ahead, DS}, {"staged", two_staged, DS}}; RUN(v);
  } else if (!strcmp(kname, "nested")) {
    n = bytes / 64; uint64_t *pool = alloc(bytes); rows = alloc(m * sizeof(Row)); uint32_t *perm = alloc(n * 4);
    for (uint64_t i = 0; i < bytes / 8; i++) pool[i] = rnd();
    for (uint64_t i = 0; i < n; i++) perm[i] = i;
    for (uint64_t i = n - 1; i > 0; i--) { uint64_t j = rnd() % (i + 1); uint32_t t = perm[i]; perm[i] = perm[j]; perm[j] = t; }
    for (uint64_t i = 0; i < m; i++) { uint32_t b = perm[i % n]; rows[i].ptr = pool + 8ull * b; rows[i].len = 1 + mix(b) % 8; rows[i].cap = 8; }
    Variant v[] = {{"base", nested_base}, {"ahead", nested_ahead, DS}}; RUN(v);
  } else if (!strcmp(kname, "chains")) {
    n = bytes / 16 - 1; ln = alloc(bytes); heads = alloc(m * 4); uint32_t *perm = alloc(n * 4), *hd = alloc(n * 4);
    for (uint64_t i = 0; i < n; i++) perm[i] = i + 1;
    for (uint64_t i = n - 1; i > 0; i--) { uint64_t j = rnd() % (i + 1); uint32_t t = perm[i]; perm[i] = perm[j]; perm[j] = t; }
    uint64_t nl = 0;
    for (uint64_t i = 0; i < n;) { uint64_t len = 1 + rnd() % 15; if (i + len > n) len = n - i; hd[nl++] = perm[i];
      for (uint64_t k = 0; k < len; k++) { Link *l = &ln[perm[i + k]]; l->val = rnd(); l->next = k + 1 < len ? perm[i + k + 1] : 0; } i += len; }
    ln[0].val = 0; ln[0].next = 0;
    for (uint64_t i = 0; i < m; i++) heads[i] = hd[i % nl];
    Variant v[] = {{"base", chains_base}, {"ahead", chains_ahead, DS}, {"group", chains_group, GS}, {"amac", chains_amac, GS}}; RUN(v);
  } else if (!strcmp(kname, "combo")) {
    n = bytes / 128; uint64_t nt = bytes / 32 - 1; cmask = bytes / 16 - 1;
    ha = alloc(bytes / 2); tn = alloc(bytes / 2); tperm = alloc(nt * 4); gidx = alloc(m * 4);
    for (uint64_t i = 0; i < n; i++) for (int k = 0; k < 8; k++) (&ha[i].key)[k] = rnd();
    for (uint64_t i = 0; i < m; i++) gidx[i] = rnd() % n;
    for (uint64_t i = 0; i < nt; i++) tperm[i] = i + 1;
    for (uint64_t i = nt - 1; i > 0; i--) { uint64_t j = rnd() % (i + 1); uint32_t t = tperm[i]; tperm[i] = tperm[j]; tperm[j] = t; }
    troot = tbuild(0, nt);
    Variant v[] = {{"base", combo_base}, {"ahead", combo_ahead, 3, {8, 32, 64}}, {"inter", combo_inter, GS},
                   {"both", combo_both, GS}, {"both32", combo_both32, GS}, {"staged", combo_staged, GS}}; RUN(v);
  } else return 2;
  return 0;
}
