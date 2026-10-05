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

## What holds

## Findings
