#include "zane_internal.h"

/* ---------------------------------------------------------------------- */
/* Slots held for checked drains (memory.md §3.2, docs/design/lowering.md L8) */
/* ---------------------------------------------------------------------- */

/* A slot is a place in its scope's frame that lowering fixed, so placing
   one costs nothing at run time. When drains are checked, a slot whose
   value may own blocks is listed, with its type, as its value arrives, so
   the drain can return them; the list's nodes are the checking's own, and
   go with the drain. Only the innermost scope ever places a slot. */
void zane_hold(char *slot, const zane_type *type) {
	zane_mark *m = zane_self->top;
	zane_held *h = malloc(sizeof *h);
	if (!h) zane_broken("out of memory for a held slot");
	*h = (zane_held){ m->held, slot, type };
	m->held = h;
}
