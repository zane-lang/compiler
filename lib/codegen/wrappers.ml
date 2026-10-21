(* The functions an unoptimized build inlines into every caller
   (docs/design/optimization.md O12).

   `core` writes even `Int +` as a one-line wrapper over an intrinsic, and a
   program that calls each one runs several times slower than one that has
   them inlined. LLVM's own inliner weighs a call by what the passes after it
   in an optimized build will make of the result. Without those passes a
   callee's locals stay the caller's for good, so inlining functions that
   hold large value arrays into one caller can make its frame overflow the
   stack. An unoptimized build therefore inlines only what [mark] picks, by
   LLVM's always-inliner: a function at most [most] instructions long,
   whose locals each take at most [largest] bytes, which is not [shared],
   and every function it calls that has a body in the module is picked too.
   A function that can reach itself is never picked, since nothing on the
   cycle is picked first. *)

(* The type an `alloca` makes room for (llvm_stubs.c). *)
external allocated_type : Llvm.llvalue -> Llvm.lltype = "zane_allocated_type"

let most = 24
let largest = 64L

let fold_instrs g init f = Llvm.fold_left_blocks (fun acc b -> Llvm.fold_left_instrs g acc b) init f

(* The functions with a body in the module that [f] calls by name. *)
let callees f =
  fold_instrs
    (fun acc i ->
      match Llvm.instr_opcode i with
      | Llvm.Opcode.Call | Llvm.Opcode.Invoke ->
          let callee = Llvm.operand i (Llvm.num_operands i - 1) in
          if Llvm.classify_value callee = Llvm.ValueKind.Function && not (Llvm.is_declaration callee)
          then callee :: acc
          else acc
      | _ -> acc)
    [] f

(* Whether every local [f] holds is one value of at most [largest] bytes. *)
let small_locals data_layout f =
  fold_instrs
    (fun ok i ->
      ok
      && (Llvm.instr_opcode i <> Llvm.Opcode.Alloca
         || Llvm.int64_of_const (Llvm.operand i 0) = Some 1L
            && Llvm_target.DataLayout.abi_size (allocated_type i) data_layout <= largest))
    true f

(* A generic instance or a package constant, which an object defines for
   every object that links with it (docs/design/separate-compilation.md
   C4), and which LLVM would drop once inlined into every caller here. *)
let shared f =
  List.mem (Llvm.linkage f) Llvm.Linkage.[ Link_once; Link_once_odr; Weak; Weak_odr ]

let never_inlined f =
  let noinline = Llvm.enum_attr_kind "noinline" in
  Array.exists
    (fun a -> match Llvm.repr_of_attr a with Llvm.AttrRepr.Enum (k, _) -> k = noinline | _ -> false)
    (Emit.function_attrs f Llvm.AttrIndex.Function)

(* Every function [m] has that the rule above picks, marked
   `alwaysinline`. *)
let mark data_layout m =
  let candidates =
    Llvm.fold_left_functions
      (fun acc f ->
        if
          (not (Llvm.is_declaration f))
          && not (shared f)
          && fold_instrs (fun n _ -> n + 1) 0 f <= most
          && small_locals data_layout f
          && not (never_inlined f)
        then (f, callees f) :: acc
        else acc)
      [] m
  in
  let picked = Hashtbl.create 64 in
  let rec grow () =
    let added =
      List.fold_left
        (fun added (f, calls) ->
          if (not (Hashtbl.mem picked f)) && List.for_all (Hashtbl.mem picked) calls then begin
            Hashtbl.replace picked f ();
            true
          end
          else added)
        false candidates
    in
    if added then grow ()
  in
  grow ();
  let always = Llvm.create_enum_attr (Llvm.module_context m) "alwaysinline" 0L in
  Hashtbl.iter (fun f () -> Llvm.add_function_attr f always Llvm.AttrIndex.Function) picked
