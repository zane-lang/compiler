# Memory semantics: what the compiler does, probed

An exploratory test of the compiler's memory semantics against the spec's
[`memory.md`](https://github.com/zane-lang/spec/blob/d0334a3/spec/memory.md)
and [`lifetimes.md`](https://github.com/zane-lang/spec/blob/d0334a3/spec/lifetimes.md)
(spec commit `d0334a3`), compiler commit `5bc7684`.

Each probe is a small Zane program in
[`tests/memory-probes/`](../tests/memory-probes/), one package per
directory. Every line the spec rejects is marked `ILLEGAL` in a comment,
every case the spec leaves unsettled `QUESTION`, and everything else should
be accepted; programs that check are also built and run, and print `yes` for
each runtime check that holds. `tests/memory-probes/run` reruns them all and
writes what the compiler and the program printed to `NAME.out`, which is
committed, so a behaviour change shows as a diff. The probes are not part of
`dune runtest`.

Findings are numbered and classified:

- **Bug** — the compiler does something the spec says it must not.
- **Gap** — the compiler accepts or rejects something where the spec is
  silent, ambiguous or self-contradictory; a spec question as much as a
  compiler one.
- **Nit** — behaviour is right, but a diagnostic is misleading.

## Summary

| # | Kind | Probe | Finding |
|---|---|---|---|
| 6 | Bug | `lambdas` | A call through a function value records no resting place, so a reference dangles and a write through it corrupts a live object |
| 7 | Bug | `deepvalue` | Overwriting a recursive value deeper than about 22,700 levels overflows the C stack and segfaults |
| 11 | Bug | `storeorder`, `subjectorder` | `list[i] = <grows list>` and `list[i]!m(<grows list>)` write into the list's freed block |
| 10 | Bug | `binders` | A match binder dangles once its arm overwrites the scrutinee |
| 9 | Bug | `aliasing`, `blockalias` | A borrowed list element or payload is freed by the same call's `mut` subject or block argument, and then read |
| 8 | Bug | `aliasing` | A value parameter is passed by copy, which `v!setFrom(v)` observes; memory.md §2.9 makes it a borrow |
| 1 | Bug | `reflist` | Nothing can be pushed into a `List<&T>` |
| 2 | Gap | `genref` | `Box(r)` with `r &Port` infers `Box<Port>`; no way to make a `Box<&Port>` |
| 3 | Nit | `genref` | An error inside a generic instance names neither the instance nor the call that made it |
| 4 | Gap | `modes` | Returning `&T` minted from a package constant is accepted; `lifetimes.md` §1.7 says only an `&T` parameter is a root |
| 5 | Nit | `downstream` | The transitive value-downstream error calls `&Engine` "a reference type" |

## What holds

Everything below behaves as the spec says, in the unoptimized and the
optimized build alike.

- **Settled and roaming** (`settled`, `modes`; memory.md §2.1, §2.8,
  §2.9). A settled owner is never a move-source; a roaming one is never a
  reference source; `&` and `^` over a value type are rejected; the subject
  and borrows are neither moved, stored, returned nor minted from; every
  parameter is read-only, so a `^T` parameter is never refilled or `!`-called;
  a spent symbol and a spent field are reported until refilled, and only in
  the declaring block; `&T` returns and aborts are rooted only in `&T`
  parameters (but see 4).
- **Value-downstream** (`downstream`; §2.10). Every reference type, `&`, `List`,
  `ArrayRef` and `Array` of either inside a value type is reported, through
  nested value fields and through a generic value type's instance; a
  recursive value variant is accepted.
- **Settled overwrite in place** (`overwrite`; §2.2, §3.6). A reference to an
  owner, to its field, or to a field below a boxed member observes a field
  overwrite, a whole-owner overwrite, and a moved-in replacement, and still
  does after 100,000 overwrites in a loop.
- **Deep value copies and overlapping overwrites** (`copies`; §2.3). Copies of
  strings, structs of strings and recursive value variants are independent of
  their source; `s = s`, `s = s + s`, `c = c`, `c = c.more`,
  `t = t.node.right`, `f.left = f.right` and `f.right = Tree.node(f)` all read
  the pre-overwrite value.
- **Moves** (`moves`; lifetimes.md §1.2–§1.9). Chains of moves, relays through
  `^T` parameters, a field moved out of a roaming root and refilled, ignored
  `^T` results, owners pushed into a growing list and overwritten there.
- **Escapes** (`escapes`; memory.md §3.5). Values and roaming owners whose
  blocks were made in a draining scope — stored outward from nested blocks,
  overwriting an outer settled owner, returned through 30 recursive scopes,
  aborted with, yielded from a match arm — arrive with their data intact,
  and the runtime finds no block left out at any drain.
- **Reclamation** (`reclaim.py`, `reclaim.out`; memory.md §3.2, lifetimes.md
  §2.1). Eleven allocating loop bodies — settled and element overwrites, string
  copies and concatenation, ignored `^T` results, block-local owners, refilled
  roaming owners, deep copies, rebuilt lists, owners resolved out of a
  handler — keep the same peak RSS (about
  10 MB) at 10,000 and at 1,000,000 iterations. The control, which keeps one
  owner per iteration in a list, grows to 73 MB, so the measurement can see
  growth.
- **The store rule** (`launder`; lifetimes.md §1.1, §1.10, §1.11). Twenty
  routes for storing a reference to an inner-block owner into an outer place
  are all reported: through a local, a call result, a method result, a function value's result, either
  side of `??`, a field, a nested field, a resting place, a resting place
  reached through mutual recursion, `push` of a value carrying one, an
  element overwrite, an element's field, an `ArrayRef` element, a generic
  field and a generic resting place, a moved roaming value, and a nested
  construction. The same stores of an outer owner are accepted.

- **Self-overlapping stores of owners** (`selfstore`; memory.md §2.2, §3.5,
  §2.8.1). `r = r` and `r = relay(r)` on a roaming owner, `r.engine =
  r.engine`, a settled owner overwritten with a value a call built from its
  own contents, a field rebuilt from itself, and an object wired to its own
  part after it settles, which then observes that part's overwrite and the
  whole object's.
- **Reference variants and `ArrayRef`** (`variants`, `payloads`; memory.md
  §2.2, §2.8, §2.8.1). A reference to a `#variant` observes each case change;
  100,000 case changes in a loop; a binder writes its payload in place;
  `ArrayRef` element references observe element and whole-array overwrites,
  including ones made from an inner block whose blocks then drain.
  A payload is never a reference or move source, through a binder or an
  `&T` parameter; an `ArrayRef` element is never moved out, under a settled
  or a roaming root.
- **Spent symbols** (`spent`; lifetimes.md §1.3, §1.6, §1.8). The order of a
  statement's own arguments is respected (read-then-move passes,
  move-then-read is reported); `risky(cup) ?? see(cup)` is reported, since
  passing to `^T` spends whatever happens; moves inside a handler, an arm
  and a `return` written in a block argument are reported as moves from a
  nested block; a field two steps into a roaming root is moved out, read
  spent, refilled, and its roots are partly spent until then.
- **Stores through a reference** (`throughref`; lifetimes.md §1.1). `r.engine
  = …`, `r.engine.power = …` with `r` an `&` local, and `car.peer.power =
  …` are all reported, and the same changes made by a `!` call through the
  reference are accepted.
- **Spawned calls** (`spawnstore`, `watertower`; lifetimes.md §2.2,
  concurrency.md §4.1). A spawned call's result, its resting places and a
  value it returns carrying a reference are checked as a plain call's are.
  A block whose spawned calls still read its owners drains only after
  them: ten spawned readers, each 200,000 reads long, see their own owner
  even though the next pass reuses its slot.
- **One object reached twice by a call** (`aliasing`; memory.md §2.9).
  `keepAndRead(cup, cup)`, a borrow and a take of one owner, is reported. A
  reference-type `mut` subject and a borrow of the same object agree: the
  borrow sees the subject's write. (But see 8 and 9.)
- **Resting places across packages** (`across`; lifetimes.md §1.11). A
  dependency's `wire`, its transitive `relay`, a result naming an argument,
  a result read through an `&` field of an `&T` parameter, and a field
  constructor's result are all checked at the importing package's calls.
- **Package constants and direct initialization** (`constants`; memory.md
  §2.8, §2.11). A reference to a constant is minted and stored; a constant is
  never moved, overwritten or `!`-called, and `^` is refused on one. A
  declaration without a value is rejected, as a parse error.
- **Owners through aborts** (`aborts`; lifetimes.md §1.7). An aborted owner
  resolved out of its handler and moved on, a result moved through `??`,
  ignored abortable results, 100,000 aborted owners in a loop, and an owning
  symbol overwritten from a handler.
- **Oversized blocks** (`oversized`; memory.md §3.1, §3.6). A 3.2 MB list
  returned out of its scope, a 2 MiB string copied out of an inner block, a
  list of 100,000 strings, and a big list overwritten 20 times.

Consequences of the spec worth knowing, all correctly implemented:

- A roaming recursive structure cannot be grown in a loop: a loop body is a
  nested block, and a roaming owner moves only in its own (lifetimes.md
  §1.3). It is built by recursion instead (`escapes`, `grow`).
- After a `mut` method stores an `&T` parameter into `this`, `this` reaches a
  read-only reference, so no further `!` call on `this` is allowed in that
  body (effects.md §4.4). A block argument counts as running any number of
  times (`design/semantics.md` §9), so a store inside
  `@controlflow$branch(…, { … })` followed by the next run's `!` call is
  rejected even though `branch` runs its block at most once. The same holds
  for spawns: a `spawn x!m()` in any block argument must take its subject
  from storage declared in that block.
- A `#struct` whose `&` field names its own type can never get a first
  instance: there is no null reference and every symbol is directly
  initialized (memory.md §2.11, lifetimes.md §2.4) (`throughref`, `Loop`).
- A value copied from a place it then overwrites, `acc = Count.more(acc)`,
  is a deep copy each time (memory.md §2.3), so growing a recursive value in
  a loop costs time quadratic in its depth.
- The runtime caps scopes nested at once at 32,768 (`ZANE_DEPTH`) and stops
  with "scopes nested too deep" past it, so a recursion deeper than that ends
  cleanly. The spec states no limit.

## Findings

### 11. An element store resolves its destination before its value (bug)

Probe `storeorder`. When the right-hand side of an element store grows the
same list, the store writes to where the element *was*:

```zane
ints[Int(1)] = ints!growAndGive(Int(1000));   // pushes 1,000, returns 4242
// ints[Int(1)] is still 1: 4242 went into the block the list gave back
```

The destination's address is computed first, the right-hand side then
relocates the backing store and returns the old block to its size stack, and
the store lands in that freed block. For `List<Int>` the element keeps its
old value; for `List<Engine>` the same; and with both cases in one program
the first write corrupts the allocator's free stack and the second
segfaults inside `zane_alloc`. (Something allocated after each list keeps
the growth from happening in place, which would hide the bug.)

A `!` call has the same order problem (probe `subjectorder`):
`engines[Int(1)]!setTo(engines!growAndGive(Int(1000)))` takes the subject's
address, then evaluates the argument, which relocates the list, and
`setTo`'s write goes into the freed block; the element keeps its old value.

memory.md §2.3 fixes that the right-hand side is evaluated against the
destination's pre-overwrite state, but not when a place destination is
resolved relative to its value. Either the compiler resolves a subscript
destination or subject after evaluating the right-hand side and the
arguments, or it rejects a `!` call on the list (or on anything owning it)
inside a store into, or a call on, one of its elements; the spec should say
which.

### 10. A match binder dangles after its arm overwrites the scrutinee (bug)

Probe `binders`. The compiler makes a binder the payload's place, not a copy
(`design/semantics.md` §9: "A `match` binder is its case's payload"), and
adt.md §5 agrees that it "behaves as that case's payload" and that the
scrutinee "stays in scope". Nothing stops the arm from overwriting the
scrutinee, which destroys the payload under the binder:

```zane
n Int = match (slot) {
	e full {
		slot = Slot.empty(Unit());   // destroys e's payload
		churn();                     // reuses its blocks
		return e.power;              // not 42
	}
	u empty => Int(0);
}
```

For a `#variant` the read returns garbage. For a value `variant` with a
`String` payload, returning the binder copies a string through a freed
handle. The committed probe prints `NO` for it in both builds; an earlier
version of the same probe, differing only in code after it, had the
unoptimized build stop with `zane runtime: out of memory for a dynamic
chunk` (status 134) while the optimized build printed `NO` — the two builds
disagreeing, as undefined behaviour may. A `mut` call on the
scrutinee in the arm, `slot!clear()`, which changes its case, does the same.

The fix is the binder's counterpart of 9: while a binder is live, its
scrutinee may not be overwritten, nor be a `mut` subject (a `mut` method
could change its case), in the arm. The spec should state it; adt.md is
silent.

### 9. A call's `mut` subject or block frees what its borrow names (bug)

Probe `aliasing`. A borrow argument may name storage *inside* the call's
own `mut` subject, and the callee can then destroy that storage while the
borrow still lends it. Every read of the borrow afterwards goes to a freed
block, which in the probe has already been reused:

```zane
Int clearThenRead(this Slot, e Engine) mut {
	this = Slot.empty(Unit());    // destroys the payload e names
	churn();                      // reuses its blocks
	return e.power;               // not 42
}
a Int = slot!clearThenRead(slot.full ?? Engine(Int(0), String("none")));
```

Four routes, all accepted and all reading garbage in both builds: a
`#variant` subject changing case while its payload is borrowed; a `List`
subject replaced wholesale while an element is borrowed; a `#struct` subject
replacing its list field while an element of it is borrowed; and a `List`
subject merely growing — its block relocates — while an element is borrowed
(that one needs the list's block not to be last at the frontier, or it
grows in place and the bug hides).

A block argument of the same call does it with no `mut` subject at all
(probe `blockalias`): `readAfter(slot.full ?? …, { slot = Slot.empty(Unit());
})` and `readAfter(list[Int(1)], { list = @primitives$List(Engine); })`,
where `readAfter` runs its block and then reads its borrow, both read freed
blocks. A block captures the caller's frame (control-flow.md §2), so it can
overwrite whatever the borrow points into. The subject is lent the same
way: in `other[Int(1)]!setAfter({ other = @primitives$List(Engine);
victims!push(…); })`, the block frees the element `this` names, a new list
element takes its block, and `setAfter`'s `this.power = Int(7)` then writes
into that unrelated live element.

The compiler already rejects the closest relative, a borrow and a take of
one owner in the same call ("a borrow lasts for the whole call"). The
missing rule is the same one for a `mut` subject and a block argument: a
call may not lend, as another argument, a place inside its `mut` subject, or
inside storage its block argument writes, that the callee could destroy or
move — a list element or a variant payload, or
anything reached through one. memory.md §2.9 says a borrow is "non-owning,
non-escaping access to the caller's owner for the duration of the call" but
states no such rule either, so the spec needs it too. (A borrow of a
settled field is safe: a field is overwritten in place, and the borrow
observes the replacement, as the reference-type case in finding 8 shows.)

The rule exists already for spawned calls: lend `list[Int(1)]` to a
`spawn` and then `list!push(…)` in the same block, and the compiler reports
"this writes `list`, which may be part of an owner lent through `list[]` to
a spawned call" (`spec-divergences.md` §13). A synchronous call lends for a
shorter time but to a callee that can write through its subject, so the
same reasoning applies within the call.

### 8. A value parameter is a copy, and a call can tell (bug)

Probe `aliasing`. memory.md §2.9: a value-type parameter "has one mode, the
borrow", and "passing a value by borrow is the semantic model rather than an
optimization; where a read-only borrow is indistinguishable from a copy, the
compiler may still pass a small value by copy". A `mut` subject aliasing the
same value makes the two distinguishable:

```zane
Unit setFrom(this V, other V) mut {
	this.x = Int(100);
	this.y = other.x;     // a borrow of v reads 100
	return Unit();
}
v V(Int(1), Int(2));
v!setFrom(v);             // v.y is 1: other was a copy
```

`design/lowering.md` §9 ("Values by value, for now") passes value types as
LLVM aggregates and argues "a value parameter cannot be written, so nothing
observes the difference"; the subject is the one way it can. The
reference-type form, `car!swapFrom(car)`, passes its borrow by address and
does see the write, so the two kinds of type disagree. Either the compiler
passes a value that a `mut` subject of the same call may reach by address,
or the spec forbids a call to lend one place as both its `mut` subject and
another argument; the compiler already rejects the borrow-and-take form of
the same alias.

### 7. A deep recursive value crashes the runtime (bug)

Probe `deepvalue`. A value variant `Count = variant { done Int; more Count; }`
built 30,000 levels deep by recursion, then overwritten, kills the program
with SIGSEGV in both builds. `zane_overwrite` (`runtime/value.c`) writes the
replacement into each boxed member's existing block by calling itself once
per level, and on an 8 MB stack it overflows at about 22,700 levels (the
backtrace is 22,765 `zane_overwrite` frames deep). Built in a loop with
`acc = Count.more(acc)`, it crashes the same way somewhere between 20,000
and 50,000 iterations. `zane_copy` (`runtime/block.c`) is recursive in the
same way. memory.md sets no depth limit, and the spec's own recursive
examples (`adt.md` §4) are this shape; the recursion along the last boxed
member can be a loop, which removes the limit for list-like values.

The program's output before the crash is lost too, because stdout is
buffered and the segfault never flushes it.

### 6. A function value launders a reference into a dangling one (bug)

Probe `lambdas`. `design/semantics.md` §10 lists "resting places for a
function value" as not done, and §9 says "a call through a function value
keeps nothing". The consequence is a hole in the store rule that a running
program falls through. A lambda that stores its `&T` parameter into its
subject,

```zane
wire Unit(this Plug, port &Port) mut {
	this.port = port;
	return Unit();
}
inner({
	near Port(Int(2));
	plug!wire(near);          // accepted; lifetimes.md §1.11 makes it ILLEGAL
});
```

leaves `plug.port` naming `near`'s slot after `near`'s block has drained.
The probe then declares `victim Port(Int(100))` in a fresh block, which lands
in the same slot, writes `plug.port!set(Int(999))`, and reads `victim.n`: it
is no longer 100. The same happens when the lambda is passed as a
`Unit[this Plug, &Port] mut` parameter and called there, and when a lambda
`push`es a `^Plug` carrying a reference to an inner owner into an outer
`List<Plug>`. All three print `NO`, in both builds. The *result* of a call
through a function value is checked (`r = passer(near)` is reported, in
`launder`); only stores into the subject or another parameter escape.

Until function types carry a resting-place summary, a sound stopgap is the
conservative one §9 already uses for intrinsics: assume a call through a
function value stores every `&`-holding argument into its subject (when the
type is `mut`) and into every other `&`-holding parameter's object.

### 1. Nothing can be pushed into a `List<&T>` (bug)

Probe `reflist`. `memory.md` §2.2 speaks of "an `&T` stored *as an element
value*" and §2.8 reads `current &Weapon = weapons[1]` out of a
`List<&Weapon>`. The compiler accepts the type and its constructor
(`@primitives$List(PortRef)` through `alias PortRef = &Port`, since a type
argument is a bare name, `spec-divergences.md` §5), but rejects every push:

```text
refs!push(r);   // r &Port
Error: no method `push` accepts (@primitives$List<&reflist$Port>, &reflist$Port);
the candidate is `@primitives$Unit push(this @primitives$List<T>, ^T) mut`
```

Minting at the call (`refs!push(p)` with `p` settled) fails the same way. With
`T = &Port`, `^T` should take an `&Port` — `memory.md` §2.9 says what `^T` is
for a reference type and a value type, but not for `T` filled with an `&`, so
the spec needs a sentence too. The `ArrayRef<&Port, 2>` built from `[r, r]`
is accepted, so only the list's `push` is affected. As it stands a list of
references can be declared but never filled.

### 2. `Box(r)` infers `Box<Port>` from an `&Port` argument (gap)

Probe `genref`. With `Box<T>(item T Type)` and `r &Port`, `Box(r)` infers
`T = Port`, so `a Box<&Port> = Box(r)` is a type mismatch. A constructor call
takes no `< >` and a type argument is passed only as a bare name, so there is
no other way to ask for `Box<&Port>`. The instance it does make, `Box<Port>`,
then fails because a bare `T` over a reference type is a borrow. The spec's
idiom for a generic that stores a reference is a dedicated `Pin<T>(at &T
Type)` over a `&T` field (generics.md §3.2), and that works; but
generics.md never says whether inference from an `&X` argument binds `T` to
`X` or to `&X`, and `List<&T>` shows the compiler does allow `T` to be an `&`.

### 3. An error inside a generic instance names nothing that made it (nit)

Probe `genref`. The `Box<Port>` instance from 2 reports

```text
File "genref/main.zn", line 18 ...
18 | Box<T>(item T Type) => init{ item; }
Error: `item` is a borrow: ...
```

against the generic's own text, with no mention of `Box<Port>` or of line 26,
whose call made the instance; delete line 26 and the error goes away.
`design/semantics.md` §9 says such an error "is reported inside the
instance, which names the call that required it".

### 4. A reference to a package constant may be returned (gap)

Probe `modes`. `&Engine constRef() => garage`, with `garage` a package
constant, is accepted. `lifetimes.md` §1.7 says a returned `&T` must be
rooted in an `&T` parameter and "Nothing else is a root", listing locals,
`^T` parameters and borrows as excluded; a package constant is not mentioned.
The store rule (§1.1) it says the rule comes from would allow it, since a
package constant outlives every caller, and memory.md §2.8 lists a package
constant as a reference source. The compiler follows §1.1; §1.7 should say
so or exclude it.

### 5. "`&Engine` is a reference type" (nit)

Probe `downstream`. The transitive form of the value-downstream error reads
"`&downstream$Engine` is a reference type, and it reaches
`downstream$Inner`'s field `e`…". `&Engine` is a reference, not a reference
type (memory.md §2.4); the direct form of the same error words it correctly
("cannot be an `&`").
