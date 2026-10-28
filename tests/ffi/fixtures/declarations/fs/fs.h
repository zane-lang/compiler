#include <zane_ffi.h>

typedef struct zane_fs_t zane_fs_t;
typedef struct zane_file_t zane_file_t;

extern zane_fs_t zane_fs;

zane_file_t *zane_fopen(zane_fs_t *fs, zane_bytes path);
void zane_fwrite(zane_fs_t *fs, zane_file_t *file, zane_bytes data);
int64_t zane_fsize(const zane_fs_t *fs, const zane_file_t *file);
void zane_fclose(zane_file_t *file);
