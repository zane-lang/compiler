#include "fs.h"

struct zane_fs_t { int unused; };

zane_fs_t zane_fs;
__attribute__((weak)) zane_fs_t zane_spare;
extern zane_fs_t zane_other __attribute__((alias("zane_fs")));
