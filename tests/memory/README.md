# Memory tests

The memory model end to end: hosting, guests, moves and the store rule of
memory.md and lifetimes.md. Each directory under `fixtures/run/` is a package
that keeps every rule, is built, and runs; `golden/NAME.out` holds what it
wrote, and each check in it prints `yes` when it holds. Each directory under
`fixtures/reject/` is a package that breaks the rules its comments name, and
`golden/reject.NAME.err` holds what `zanec --check` reports for it. A reject
package states the legal form beside each illegal one, so its golden file
shows both what is refused and that nothing else is.

The rules are written by `tests/gen/gen_rules.ml` into `dune.inc`, as for
tests/codegen: add the directory and an empty golden file, run `dune
runtest`, check the new rules in the `dune.inc` diff and `dune promote`, then
run it again, read the golden diff and promote that.

## Programs that run

- `carried` is lifetimes.md §1.10's legal side: values whose `&` member names
  a host, stored from an inner block into hosts owned above it where that
  host outlives them, pushed into lists, built by a verb whose parameter rests
  in its result, and case forms that name nothing. A value whose guest names
  a host inside itself leaves the call and the block that built it, and its
  guest follows the host it owns through every move.
- `floats` is memory.md §2.8.1: stable slots overwritten from inner blocks
  keep their guests, and list elements and variant payloads replaced or
  changed away float their occupant into the place's owner, so a guest
  minted before the move outlives the block that made the change.
- `lending` is lifetimes.md §1.5, §1.8 and §1.9: a swallowed value lent into
  a callee's local outlives that local, a relayed host comes back bound or
  floats, a swallowed parameter is returned as a guest, and a guest parameter
  leaves the caller hosting.
- `stores` is the store rule's legal side (lifetimes.md §1.1, §1.7, §1.11):
  guests to outer hosts stored into deeper blocks and `&` fields, and calls
  whose parameters come to rest in another parameter, through one, two and
  three calls, with the recorded steps kept.

## Packages that are refused

- `carried` is the case a carried guest exists for: a car naming an engine an
  inner block owns, taken out of that block: assigned, returned, moved into a hosting field, a list or a case form, and handed to
  a call that keeps it.
- `stores` stores guests to inner hosts into `&` locals and fields owned
  above, directly, copied, and through a verb's result; and one to a
  host that only later moves to an outer list.
- `returns` is lifetimes.md §1.7: guests rooted in the body, and the
  parameter roots that are legal.
- `moves` is lifetimes.md §1.2–1.6 beyond tests/semantics: a parameter moved
  below the body's top, every use of a spent symbol, a destination below the
  source, and a field of a host moved whole.
- `rests` is lifetimes.md §1.11 with its own `Terminal` and `Hub`: calls
  whose recorded resting places, substituted, store an inner guest above.
- `sources` is memory.md §2.8, §2.4 and §2.10: guests minted from a
  temporary's field and a spent symbol, and value types that hold a
  reference type or an `&`.
