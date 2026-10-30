/* A function an `__asm__` label names without the `_` every C name takes
   on Mach-O, so its symbol is `helper`, which no C name can be there. */
long long helper(void) __asm__("helper");
long long helper(void) { return 1; }
long long labelled(void) { return helper(); }
