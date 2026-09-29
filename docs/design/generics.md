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
geometry$List<%primitives$Int>
```

Every argument is qualified with its own package, so this name is already
unique across the whole program, and it identifies the instance on its own.
Nothing needs to be encoded. The one change from the source is `%` in place of
an intrinsic namespace's `@`, which a linker would read as a symbol version
([`symbols.md`](symbols.md)). Both LLVM and object files accept the name as an
identifier: LLVM quotes a name that holds characters such as `$`, `<` or spaces
(`@"geometry$List<%primitives$Int>"`), and an ELF symbol name can be any byte
string. So the name a reader sees in the source is, but for that one
character, the name the compiler uses internally, in the IR and in the binary.
That makes an instance easy to refer to and easy to find when debugging.

A generic verb's instance is named the same way, with its parameter types
after the arguments, as every verb is:

```text
geometry$first<%primitives$Int>(this geometry$List<%primitives$Int>)
```

[`symbols.md`](symbols.md) gives the naming rules for every type, verb and
variable, generic or not.
