/* The runtime's anchors and tethers, tested in C on their own
   (docs/lowering.md L17), over hand-written layouts. Each check prints `yes`
   when it holds and `no` when it does not. */

#include "../../runtime/zane.c"

#include <stddef.h>

static void check(int ok) { puts(ok ? "yes" : "no"); }

/* A host of one `Int`, and a host holding one stable and one variant-payload
   host of that kind: `{ bp; spare Node; slot #variant { empty; held Node } }`. */
typedef struct {
	uint32_t bp;
	int64_t value;
} node;

typedef struct {
	uint32_t bp;
	node spare;
	uint32_t slot_bp;
	int32_t tag;
	node held;
} car;

static const int64_t node_layout[] = { 1, ZANE_HOST, 0, sizeof(node), 0, 0, 0 };
static const int64_t car_layout[] = {
	3,
	ZANE_HOST, 0, sizeof(car), 0, 0, 0,
	ZANE_HOST, offsetof(car, spare), sizeof(node), 0, 0, 0,
	ZANE_HOST, offsetof(car, held), sizeof(node), 0, 0, 1, offsetof(car, tag), 1,
};

void zane_main(void) {
	int64_t scope = zane_scope_enter();

	/* A guest names its host, and minting again gives the same anchor. */
	node *a = zane_slot(scope, sizeof(node), 8, node_layout);
	*a = (node){ 0, 1 };
	uint32_t g = zane_mint(a);
	check(g != 0 && zane_mint(a) == g && zane_resolve(g) == a);

	/* A move takes the anchor along: the guest follows the host. */
	node *b = zane_slot(scope, sizeof(node), 8, node_layout);
	*b = *a;
	zane_vacate((char *)a, node_layout);
	zane_arrive((char *)b, node_layout);
	check(zane_resolve(g) == b && a->bp == 0);

	/* A stable overwrite keeps the identity: the guest sees the new host. */
	node fresh = { 0, 7 };
	zane_overwrite((char *)b, (char *)&fresh, sizeof(node), node_layout, 0);
	check(zane_resolve(g) == b && b->value == 7 && b->bp == g);

	/* Moving an anchored host into an anchored one merges them: the
	   incoming identity forwards to the one that stays. */
	node *c = zane_slot(scope, sizeof(node), 8, node_layout);
	*c = (node){ 0, 3 };
	uint32_t h = zane_mint(c);
	node moving = *c;
	zane_vacate((char *)c, node_layout);
	zane_overwrite((char *)b, (char *)&moving, sizeof(node), node_layout, 0);
	check(zane_terminal(h) == g && zane_resolve(h) == b && b->value == 3);

	/* A variant payload's anchored occupant floats when the case changes,
	   and a stable field's identity stays with the field. */
	car *k = zane_slot(scope, sizeof(car), 8, car_layout);
	*k = (car){ .spare = { 0, 5 }, .tag = 1, .held = { 0, 9 } };
	uint32_t spare = zane_mint(&k->spare), held = zane_mint(&k->held);
	car next = { .spare = { 0, 6 }, .tag = 0 };
	zane_overwrite((char *)k, (char *)&next, sizeof(car), car_layout, 0);
	node *floating = zane_resolve(held);
	check(floating != &k->held && floating->value == 9);
	check(zane_resolve(spare) == &k->spare && k->spare.value == 6);

	/* A drain retires the scope's anchors: the next one reuses a cell. */
	zane_scope_drain(scope);
	scope = zane_scope_enter();
	node *d = zane_slot(scope, sizeof(node), 8, node_layout);
	*d = (node){ 0, 0 };
	uint32_t reused = zane_mint(d);
	check(reused == g || reused == h || reused == spare);
	zane_scope_drain(scope);
}
