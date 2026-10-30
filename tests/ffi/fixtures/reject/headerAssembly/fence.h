static inline long long fenced(long long x) {
  __asm__ volatile("" : "+r"(x));
  return x;
}
