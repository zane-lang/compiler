#include <zane_ffi.h>

typedef struct conn_t conn_t;
typedef struct stmt_t stmt_t;
typedef struct fs_t fs_t;
typedef struct file_t file_t;

extern fs_t zane_fs;

conn_t *conn_open(int32_t id);
conn_t *conn_maybe(int32_t id);
void conn_set(conn_t *dst, conn_t *src);
void conn_free(conn_t *conn);
int32_t conn_id(const conn_t *conn);
void conn_bump(conn_t *conn);

stmt_t *stmt_prepare(const conn_t *conn, int32_t n);
void stmt_set(stmt_t *dst, stmt_t *src);
void stmt_free(stmt_t *stmt);
int32_t stmt_id(const stmt_t *stmt);

file_t *fs_open(fs_t *fs, zane_bytes path);
void fs_write(fs_t *fs, file_t *file, zane_bytes data);
void fs_close(file_t *file);
int64_t fs_written(const fs_t *fs);
zane_bytes fs_drain(fs_t *fs);
