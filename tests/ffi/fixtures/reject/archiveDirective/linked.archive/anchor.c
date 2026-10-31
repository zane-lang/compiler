/* Asks the link for `kept`, which the other member defines, through a
   `-include:kept` directive in the object's `.drectve` section, as
   `#pragma comment(linker, "/include:kept")` writes one for MSVC. */
__asm__(".section .drectve\n.ascii \" -include:kept\"\n.text");

long long anchor(void) { return 1; }
