/* A header defining the seed `tally` reads, which no source of the
   package includes: only the glue compiles it, and the archive's member
   reaches it by its name. */
long long tally_seed = 3;
long long tally_seeded(void);
