#ifdef _WIN32
typedef int myint;
#else
typedef long long myint;
#endif
myint scaled(myint n);
