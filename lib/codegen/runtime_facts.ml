(* What the runtime's functions do, as LLVM attributes on their
   declarations (docs/design/lowering.md §9, "What LLVM is told about the
   runtime"). An attribute is a contract on the C body, not a hint: one the
   body breaks is a miscompile, so each below is one the body in runtime/*.c
   is known to keep, and the C says so beside the function, as a constraint
   on changing it. A function whose body may stop the program (zane_broken,
   exit) says nothing of what memory it touches and is not `willreturn`;
   one that calls a walk or a thunk, code of the program's or of C, says
   nothing at all. Every function is `nounwind`: the runtime is C, which
   clang compiles so, and nothing it calls unwinds through it.

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

let none = { fn = "nounwind"; ret = ""; params = [] }

(* A fresh block of a region (arena.c): no other object the caller can
   reach shares its bytes, it is never null, and it is aligned to a word. *)
let fresh = "noalias nonnull align 8"

(* A pointer the function reads through or writes through, and keeps no
   copy of. *)
let reads = "readonly captures(none)"
let writes = "writeonly captures(none)"
let kept_not = "captures(none)"

(* A function that returns, stops nothing, waits for no thread and frees
   nothing: what LLVM may assume of a call it can move or delete. *)
let simple = "nounwind willreturn nosync nofree"

let facts = function
  (* Stop the program, off the hot path (list.c, region.c, handle.c). *)
  | R.Out_of_range | R.Too_deep | R.No_object -> { none with fn = "noreturn cold nounwind" }
  (* Allocators (arena.c, block.c). *)
  | R.Alloc | R.Alloc_held | R.Box -> { none with ret = fresh }
  (* Strings (block.c). *)
  | R.Text_equal -> { fn = "memory(read) " ^ simple; ret = ""; params = [ reads; reads ] }
  | R.Text_join -> { none with params = [ writes; reads; reads ] }
  | R.Text_taken -> { none with params = [ writes; reads ] }
  | R.Text_i32 | R.Text_i64 | R.Text_f32 | R.Text_f64 -> { none with params = [ writes ] }
  | R.Text_expect -> { none with fn = "memory(read) " ^ simple }
  | R.Print -> { none with params = [ reads ] }
  | R.Parse_i64 | R.Parse_f64 -> { none with params = [ reads; writes ] }
  | R.Arguments -> { none with params = [ writes ] }
  (* Lists (list.c). A push looks the handle's address up to find its
     region, which tells the caller something of the address, but keeps no
     pointer to the handle. A removal moves its elements in pieces, in a
     loop LLVM's own look at the body does not find returns, so it is not
     said to return here either. *)
  | R.List_new -> { fn = "memory(argmem: write) " ^ simple; ret = ""; params = [ writes ] }
  | R.List_push | R.List_reserve | R.List_room -> { none with params = [ "captures(address)" ] }
  | R.List_remove _ -> { fn = "nounwind nosync nofree"; ret = ""; params = [ kept_not ] }
  | R.List_swap_remove _ -> { fn = simple; ret = ""; params = [ kept_not ] }
  | R.Pool_root -> { fn = "memory(argmem: read) " ^ simple; ret = ""; params = [ reads ] }
  | R.Link ->
      (* The node it returns is the link moved by what it reads there. *)
      let param = "readonly captures(ret: address, provenance)" in
      { fn = "memory(argmem: read) " ^ simple; ret = ""; params = [ param ] }
  (* Regions (arena.c, value.c): an address is looked up, never read. *)
  | R.Region_at -> { none with params = [ "readnone captures(address)" ] }
  | R.Leaves -> { none with params = [ "readnone captures(address)"; "captures(address)" ] }
  (* Slots (slot.c): cold in its C as well. *)
  | R.Hold -> { none with fn = "cold nounwind" }
  | R.Handle_made -> { none with fn = "nounwind willreturn nofree" }
  | R.Scope_enter | R.Promote | R.Arrive | R.Copy | R.Overwrite | R.Array_at | R.List_at
  | R.Scope_drain | R.Spawn | R.Join | R.Set_threads | R.Set_threads_auto | R.Snapshot
  | R.Constant_begin | R.Constant_end | R.Writeback | R.Free | R.Defer | R.Defer_return
  | R.Pool_new | R.Pool_push | R.Pool_append | R.Pool_copy | R.Pool_reserve
  | R.Pool_new_unbounded | R.Overwrite_handles | R.Overwrite_settled | R.Handle_end
  | R.Handle_set | R.Callback_attach | R.Callback_detach | R.Island ->
      none

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
