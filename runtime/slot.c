#include "zane_internal.h"

/* ---------------------------------------------------------------------- */
/* Slots held for drains (memory.md §3.2, docs/design/lowering.md L8)    */
/* ---------------------------------------------------------------------- */

/* A slot is a place in its scope's frame that lowering fixed, so placing
   one costs nothing at run time. When drains are checked, a slot whose
   value may own blocks is listed, with its type, as its value arrives, so
   the drain can return them; a slot whose value may hold a foreign handle
   is listed whether or not they are, so the drain ends the handle
   (docs/design/ffi.md F12). The list's nodes are the drain's own, and go
   with it. Only the innermost scope ever places a slot. It runs only for
   those slots, so it is cold, and is never copied into a program as a body
   to inline (lib/codegen/runtime_bodies.ml). */
__attribute__((cold)) void zane_hold(char *slot, const zane_type *type) {
	zane_mark *m = zane_self->top;
	zane_held *h = malloc(sizeof *h);
	if (!h) zane_broken("out of memory for a held slot");
	*h = (zane_held){ m->held, slot, type };
	m->held = h;
}
