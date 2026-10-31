/* A second member of `tally.a`, which the link takes only for the
   function a thunk calls: the seed `seed.h` defines, which only the
   package's glue compiles, read by its name. */
extern long long tally_seed;
long long tally_seeded(void) { return tally_seed * 10 + 1; }
