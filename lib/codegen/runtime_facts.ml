(* What the runtime's functions do, as LLVM attributes on their
   declarations (docs/design/lowering.md §9, "What LLVM is told"). An
   attribute is a contract on the C body, not a hint: one the body breaks is
   a miscompile, so each below is one the body in runtime/*.c is known to
   keep. Only those that change what LLVM makes of a program are given;
   docs/perf-runtime-attrs/ records the ones measured and left out.

   How each attribute is spelled inside LLVM changes between releases, so
   LLVM's parser makes them, from a declaration written as text ([text]).

   A body the program takes from the runtime's bitcode to inline
   ([Runtime_bodies]) replaces the declaration, and with it the
   declaration's attributes, so [mark] puts them back on whatever the
   module holds under each name once the bodies are linked: on a call LLVM
   does not inline they are what it knows. *)

module R = Cgt.Runtime

(* The attributes of one function: of the function, of its result, and of
   each parameter, in order; a shorter list leaves the rest bare. *)
type facts = { fn : string; ret : string; params : string list }

let none = { fn = ""; ret = ""; params = [] }

let facts = function
  (* An index out of range and a nest of scopes too deep stop the program
     (list.c, region.c), so the path to either is cold and nothing follows
     it. *)
  | R.Out_of_range | R.Too_deep -> { none with fn = "noreturn cold nounwind" }
  (* Comparing two strings only reads them, and what their handles point
     to (block.c). *)
  | R.Text_equal ->
      let reads = "readonly captures(none)" in
      { fn = "memory(read) nounwind willreturn nosync nofree"; ret = ""; params = [ reads; reads ] }
  (* A push, a reserve and a room look the handle's address up to find its
     region (list.c, arena.c), which tells the caller something of the
     address, but keep no pointer to the handle: a handle in a slot of the
     caller's own stays the caller's across other calls. *)
  | R.List_push | R.List_reserve | R.List_room -> { none with params = [ "captures(address)" ] }
  | _ -> none

let ir_type = function
  | R.Void -> "void"
  | R.I32 -> "i32"
  | R.I64 -> "i64"
  | R.F32 -> "float"
  | R.F64 -> "double"
  | R.Ptr -> "ptr"

(* [fn]'s declaration as LLVM's text, with its attributes. *)
let text fn =
  let f = facts fn in
  let ret, params = R.signature fn in
  let attr i = match List.nth_opt f.params i with Some a -> " " ^ a | None -> "" in
  let params = List.mapi (fun i t -> ir_type t ^ attr i) params in
  Printf.sprintf "declare %s%s @f(%s) %s" (if f.ret = "" then "" else f.ret ^ " ") (ir_type ret)
    (String.concat ", " params) f.fn

(* The attributes [text] gives [fn], parsed in [ctx]: the function's, the
   result's and each parameter's. *)
let parsed ctx fn =
  let m = Llvm_irreader.parse_ir ctx (Llvm.MemoryBuffer.of_string (text fn)) in
  let f = Option.get (Llvm.lookup_function "f" m) in
  let at i = Llvm_extra.function_attrs f i in
  let n = List.length (snd (R.signature fn)) in
  let attrs =
    (Llvm.AttrIndex.Function, at Llvm.AttrIndex.Function)
    :: (Llvm.AttrIndex.Return, at Llvm.AttrIndex.Return)
    :: List.init n (fun i -> (Llvm.AttrIndex.Param i, at (Llvm.AttrIndex.Param i)))
  in
  Llvm.dispose_module m;
  attrs

(* [fn]'s attributes added to [f], the runtime's function in some module. *)
let apply f fn =
  List.iter
    (fun (index, attrs) -> Array.iter (fun a -> Llvm.add_function_attr f a index) attrs)
    (parsed (Llvm.module_context (Llvm.global_parent f)) fn)

(* Every runtime function [m] declares or holds a body of given its
   attributes, as after the runtime's bodies are linked into it. *)
let mark m =
  List.iter (fun fn -> Option.iter (fun f -> apply f fn) (Llvm.lookup_function (R.name fn) m)) R.all
