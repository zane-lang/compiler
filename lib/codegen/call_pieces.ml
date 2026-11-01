(* How many registers a value takes when it crosses a call, and how many a
   target gives one: the counts Emit.passing and Emit.returning decide by. *)

open Cgt.Nodes

let words = Ty.words


(* The registers a value of type [t] takes as itself: the scalar pieces LLVM
   splits it into, one per register. A struct's and a sum's are their
   members', a sum's tag and each word of its payload room one apiece, an
   array's its element's times its length, and `Unit` none. Counted on the
   CGT type, not LLVM's, so the count does not depend on [data_layout].
   Never more than the type's size in bytes, which is below Ty.limit. *)
let rec pieces (t : Ty.t) =
  match t with
  | Ty.Void -> 0
  | Ty.I1 | Ty.I32 | Ty.I64 | Ty.F32 | Ty.F64 | Ty.Ptr | Ty.Ref | Ty.Box32 -> 1
  | Ty.Handle | Ty.Handle16 -> 3
  | Ty.Struct ts -> List.fold_left (fun n t -> n + pieces t) 0 ts
  | Ty.Sum ts when Ty.niche ts -> 1
  | Ty.Sum ts -> 1 + words ts
  | Ty.Array (t, n) -> n * pieces t
  | Ty.Packed t -> (fst (Ty.size_align (Ty.Packed t)) + 7) / 8

(* How many of [pieces t] are floating-point. *)
let rec floats (t : Ty.t) =
  match t with
  | Ty.F32 | Ty.F64 -> 1
  | Ty.Struct ts -> List.fold_left (fun n t -> n + floats t) 0 ts
  | Ty.Array (t, n) -> n * floats t
  | _ -> 0

(* The registers a value may take and still pass as itself, which is what
   the target's C calling convention gives one aggregate: 2 on x86-64
   Linux and macOS and on AArch64, 1 on x86-64 Windows. Every target is
   64-bit (Build.sixty_four_bit). *)
let registers triple =
  match String.split_on_char '-' triple with
  | ("x86_64" | "amd64") :: rest when List.exists (String.starts_with ~prefix:"windows") rest -> 1
  | _ -> 2

(* The pieces a result may take and still come back as itself, and how many
   of them may be floating-point: what LLVM returns in registers. That is
   3 and 2 on x86-64 (rax, rdx and rcx, xmm0 and xmm1) on every system, and
   at least as many on AArch64, so a string or list handle comes back in
   registers. A third floating-point piece on x86-64 would come back
   through the x87 stack, and a fourth piece through memory LLVM
   allocates itself. Elsewhere it is the limit for an argument. *)
let results triple =
  match String.split_on_char '-' triple with
  | ("x86_64" | "x86_64h" | "amd64" | "aarch64" | "arm64" | "arm64e") :: _ -> (3, 2)
  | _ ->
      let n = registers triple in
      (n, n)

let aggregate = function
  | Ty.Struct _ | Ty.Sum _ | Ty.Array _ | Ty.Handle | Ty.Handle16 | Ty.Packed _ -> true
  | _ -> false
