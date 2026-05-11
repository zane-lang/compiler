so that generics work, a concrete type has to be made per generic.
but only once. the home-package of T in `T<U>` is responsible for
ensuring this type is only created once. so when the compiler
comes across `T<U>`, it has to call some function like `package.ensureSetUp(U)`
so that the resulting type is in T's package. this results in better overview
since all variants of the generic are predictably in T's home-package and
not spread across callers. the resulting type that is set up in the home package
has the identical name as the caller, since no mangling is required:
`List<Int>` -> representation -> `List<Int>`
this also makes using/referencing the type trivial.
