# Generic instances

A generic type or verb is compiled once for each distinct set of arguments it is
used at. This page covers two things about such an instance: which package it
belongs to, and what it is called. How a generic body is type-checked for each
instance is described in [`semantics.md`](semantics.md) D12, and how instances
reach the CGT in [`lowering.md`](lowering.md) L4.

## Where an instance lives

An instance belongs to the **home package of the generic**. When the compiler
meets `List<Int>`, it asks `List`'s package to provide that instance. It does
not build a private copy for the package that used it. So:

- each instance exists exactly once, however many packages use it;
- every variant of a generic lives in one predictable place, next to the
  generic itself, instead of being spread across its callers.

For now, the compiler builds the whole program as one module. Home-package
placement starts to matter once packages are compiled separately. The plan
already fits that model: an instance is asked for, and never copied.

## What an instance is called

An instance's name is its **fully qualified type as written**, arguments
included:

```text
geometry$List<@primitives$Int>
```

Every argument is qualified with its own package, so this name is already
unique across the whole program, and it identifies the instance on its own.
Nothing needs to be encoded or renamed. Both LLVM and object files accept it as
an identifier: LLVM quotes a name that holds characters such as `$`, `<` or
spaces (`%"geometry$List<@primitives$Int>"`), and an ELF symbol name can be any
byte string. The name a reader sees in the source is the same name the compiler
uses internally, in the IR and in the binary. That makes an instance easy to
refer to and easy to find when debugging.

## What the compiler does today

- A type's layout is keyed by its full name, `Tty.to_string` of the type
  (`layout` in `lib/cgt/lower.ml`). Each instance of a generic type gets one
  layout under its raw name.
- A verb instance is keyed by its declaration and its arguments,
  `<decl id><args>` (`key` in `lib/cgt/lower.ml`). Its LLVM symbol, however,
  is still sanitized to `zane_<name>_<decl>_<n>` (`symbol`), and layout tables
  are emitted as private `zane.layout` globals. Bringing the raw name through
  to the emitted symbols is still to be done.
