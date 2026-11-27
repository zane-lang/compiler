(* The uses of a veiled value that generics.md §3.8 forbids, each reported
   where a generic body writes it. A veiled value is one whose type is a type
   parameter, [Ty.Veiled] in the check a generic body gets where it is
   declared (docs/design/semantics.md D12). *)

open Env

(* `x.value`, read or written, and `x.colorName`, an enum map read. *)
let member env span field (p : Ty.param) =
  veiled_error env span
    (Printf.sprintf
       "this reaches %s of a veiled value, whose type is the type parameter %s; a generic body \
        reaches such a value only through methods, functions, operators, subscripts and \
        constructors, never a field or an enum map (generics.md §3.8)"
       (quote field) (quote p.Ty.name))

(* `T.red`: an enum member named through the parameter. *)
let type_member env span member (p : Ty.param) =
  veiled_error env span
    (Printf.sprintf
       "`%s.%s` names a member through the type parameter %s; a generic body names no enum \
        member through a type parameter, and `%s.%s(...)` would call a named constructor of the \
        type that fills it (generics.md §3.8)"
       p.Ty.name member (quote p.Ty.name) p.Ty.name member)

(* `match (x) { ... }`. *)
let scrutinee env span (p : Ty.param) =
  veiled_error env span
    (Printf.sprintf
       "a match dispatches on a variant or an enum, and this is a veiled value, whose type is the \
        type parameter %s; a generic body never depends on the mould of the type that fills it \
        (generics.md §3.8)"
       (quote p.Ty.name))

(* `x(1)`. *)
let call env span (p : Ty.param) =
  veiled_error env span
    (Printf.sprintf
       "this calls a veiled value, whose type is the type parameter %s, as a function value; a \
        generic body calls methods, functions, operators and constructors on such a value, never \
        the value itself (generics.md §3.8)"
       (quote p.Ty.name))
