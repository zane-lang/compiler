#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "api.h"

/* Every object made, replaced and released is logged, in the order C
   sees it, and the program prints the log. */
struct fs_t {
	char log[8192];
	size_t length;
	int64_t written;
};

fs_t zane_fs;

static void note(const char *format, ...) {
	va_list args;
	va_start(args, format);
	size_t room = sizeof zane_fs.log - zane_fs.length;
	int n = vsnprintf(zane_fs.log + zane_fs.length, room, format, args);
	va_end(args);
	if (n > 0) zane_fs.length += (size_t)n < room ? (size_t)n : room - 1;
}

struct conn_t {
	int32_t id;
};

struct stmt_t {
	int32_t id;
};

struct file_t {
	char path[64];
};

conn_t *conn_open(int32_t id) {
	conn_t *c = malloc(sizeof *c);
	c->id = id;
	note("open conn %d\n", id);
	return c;
}

conn_t *conn_maybe(int32_t id) { return id < 0 ? NULL : conn_open(id); }

void conn_set(conn_t *dst, conn_t *src) {
	note("set conn %d to %d\n", dst->id, src->id);
	dst->id = src->id;
	free(src);
}

void conn_free(conn_t *conn) {
	note("free conn %d\n", conn->id);
	free(conn);
}

int32_t conn_id(const conn_t *conn) { return conn->id; }

void conn_bump(conn_t *conn) { conn->id += 1; }

stmt_t *stmt_prepare(const conn_t *conn, int32_t n) {
	stmt_t *s = malloc(sizeof *s);
	s->id = conn->id * 100 + n;
	note("prepare stmt %d\n", s->id);
	return s;
}

void stmt_set(stmt_t *dst, stmt_t *src) {
	note("set stmt %d to %d\n", dst->id, src->id);
	dst->id = src->id;
	free(src);
}

void stmt_free(stmt_t *stmt) {
	note("free stmt %d\n", stmt->id);
	free(stmt);
}

int32_t stmt_id(const stmt_t *stmt) { return stmt->id; }

file_t *fs_open(fs_t *fs, zane_bytes path) {
	(void)fs;
	file_t *f = calloc(1, sizeof *f);
	size_t n = path.size < sizeof f->path - 1 ? path.size : sizeof f->path - 1;
	memcpy(f->path, path.data, n);
	note("open %s\n", f->path);
	return f;
}

void fs_write(fs_t *fs, file_t *file, zane_bytes data) {
	fs->written += (int64_t)data.size;
	note("write %lld bytes to %s\n", (long long)data.size, file->path);
}

void fs_close(file_t *file) {
	note("close %s\n", file->path);
	free(file);
}

int64_t fs_written(const fs_t *fs) { return fs->written; }

zane_bytes fs_drain(fs_t *fs) {
	zane_bytes log = { (const uint8_t *)fs->log, fs->length };
	fs->length = 0;
	return log;
}
