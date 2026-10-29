/* What `tally` calls back, and `landing`, which `hop` jumps to: both
   named as the other package's are. */
long long tally_hook(void) { return 27; }

long long landing(long long x) { return x * 3; }
