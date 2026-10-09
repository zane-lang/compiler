#include "zane_internal.h"

/* ---------------------------------------------------------------------- */
/* Slots and drains (memory.md §3.2, docs/design/lowering.md L8)                 */
/* ---------------------------------------------------------------------- */

/* A zeroed slot in the innermost scope's arena, which is the only one a
   program ever places a slot in. When drains are checked, a slot whose
   value may own blocks is listed, with its type, so the drain can return
   them; one filled later holds nothing until then. */
void *zane_slot(int64_t scope, int64_t size, int64_t align, const zane_type *type) {
	zane_context *c = zane_self;
	if (scope != c->depth - 1) zane_broken("a slot placed in a scope that is not innermost");
	zane_mark *m = zane_mark_at(c, scope);
	zane_lock(c);
	char *slot = zane_bump(size, align);
	memset(slot, 0, (size_t)size);
	if (zane_checking && type) {
		zane_held *h = zane_bump(sizeof *h, 8);
		*h = (zane_held){ m->held, slot, type };
		m->held = h;
	}
	zane_unlock(c);
	return slot;
}
