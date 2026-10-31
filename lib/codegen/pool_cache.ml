(* Experimental (docs/experiments/goose-comparison): with
   `ZANE_POOL_REGISTERS=1`, a function that builds into a pool it is given
   (Lower.into) keeps the pool's items, count and room in slots of its own,
   which LLVM promotes to registers, as Goose keeps a data stack's top in a
   local where a function grows it (its implementation notes, §6.10). A
   push writes its node and moves the count there, and calls the runtime
   only when the pool is full. The count goes back to the pool before
   anything else is handed the pool and at every return, and all three are
   read again after anything else was handed it.

   With `ZANE_POOL_UNCHECKED=1` too, a push does not check the pool's room:
   every pool such a function can be given is made where a value needs one
   (Lower.pool_value), and that is made in a block that never needs to grow
   (runtime/arena.c, `zane_alloc_unbounded`), as Goose reserves a data
   stack whose growth it never checks (its specification, §1.3). Not with
   ZANE_REF32=1: each such block takes 2 GiB of the cage's 28 GiB, which a
   few threads' pools use up. *)

open Cgt.Nodes

let unchecked () = Sys.getenv_opt "ZANE_POOL_UNCHECKED" = Some "1" && not (Cgt.Ref32.on ())
let on () = Sys.getenv_opt "ZANE_POOL_REGISTERS" = Some "1" || Sys.getenv_opt "ZANE_POOL_UNCHECKED" = Some "1"

(* The locals that hold [f]'s pool's address, its parameter first: a
   pointer parameter that some push builds into, and every local bound to
   one of them. [] when there is none, or when one is used other than as
   an argument or to bind another, where the slots would miss a write. *)
let pool_locals (f : Func.t) : int list =
  let lets = ref [] and assigned = ref [] and pushed = ref [] and addressed = ref [] in
  let locals = ref [] and passed = ref [] in
  let args_of (e : Expr.t) =
    match e.Expr.node with
    | Expr.Call { args; _ } | Expr.Runtime { args; _ } -> args
    | Expr.Call_value { args; _ } -> args
    | _ -> []
  in
  Cgt.Traverse.walk_stats
    (fun (e : Expr.t) ->
      (match e.Expr.node with
      | Expr.Local x -> locals := x :: !locals
      | Expr.Address x -> addressed := x :: !addressed
      | Expr.Runtime { fn = Cgt.Runtime.Pool_push; args = { Expr.node = Expr.Local x; _ } :: _ } ->
          pushed := x :: !pushed
      | _ -> ());
      List.iter
        (fun (a : Expr.t) -> match a.Expr.node with Expr.Local x -> passed := x :: !passed | _ -> ())
        (args_of e))
    (function
      | Stat.Let { id; value = { Expr.node = Expr.Local x; _ } } -> lets := (id, x) :: !lets
      | Stat.Assign { place; _ } -> assigned := place.local :: !assigned
      | _ -> ())
    f.Func.body;
  let rec close ids =
    let more = List.filter_map (fun (a, x) -> if List.mem x ids && not (List.mem a ids) then Some a else None) !lets in
    if more = [] then ids else close (ids @ more)
  in
  let count x l = List.length (List.filter (( = ) x) l) in
  let fits ids =
    List.exists (fun x -> List.mem x !pushed) ids
    && List.for_all
         (fun x ->
           (not (List.mem x !assigned))
           && (not (List.mem x !addressed))
           && count x !locals = count x !passed + List.length (List.filter (fun (_, y) -> y = x) !lets))
         ids
  in
  match List.find_opt (fun (p, t) -> t = Ty.Ptr && fits (close [ p ])) f.Func.params with
  | Some (p, _) -> close [ p ]
  | None -> []

type t = { ids : int list; handle : Llvm.llvalue; items : Llvm.llvalue; count : Llvm.llvalue; room : Llvm.llvalue }

(* The pool the function being built keeps in slots, while it is built. *)
let current : t option ref = ref None

let held x = match !current with Some c -> List.mem x c.ids | None -> false

(* Whether a call or a runtime function is handed the pool. *)
let handed (args : Expr.t list) = List.exists (fun (a : Expr.t) -> match a.Expr.node with Expr.Local x -> held x | _ -> false) args

(* The slots read from the pool, as the function starts and after anything
   else was handed it. *)
let reload ctx b c =
  let load slot v = ignore (Llvm.build_store v slot b) in
  load c.items (List_handle.items ctx b c.handle);
  load c.count (List_handle.count ctx b c.handle);
  load c.room (List_handle.room ctx b c.handle)

(* The count written back, before anything else is handed the pool. *)
let flush ctx b c = List_handle.set_count ctx b (Llvm.build_load (Llvm.i64_type ctx) c.count "" b) c.handle

let start ctx b ~alloca ids handle =
  let c =
    {
      ids;
      handle;
      items = alloca (Llvm.pointer_type ctx);
      count = alloca (Llvm.i64_type ctx);
      room = alloca (Llvm.i64_type ctx);
    }
  in
  reload ctx b c;
  c

let declared m name t = match Llvm.lookup_function name m with Some f -> f | None -> Llvm.declare_function name t m

(* A push (runtime/list.c, `zane_pool_push`) of the node of [size] bytes at
   [node], with a link to each [(offset, at)]: the node's offset in the
   pool. *)
let push ctx m b c node size links =
  let i64 = Llvm.i64_type ctx and ptr = Llvm.pointer_type ctx and i32 = Llvm.i32_type ctx in
  let int k = Llvm.const_int i64 k in
  let at = Llvm.build_load i64 c.count "" b in
  let next = Llvm.build_add at (int size) "" b in
  if not (unchecked ()) then begin
    let full = Llvm.build_icmp Llvm.Icmp.Sgt next (Llvm.build_load i64 c.room "" b) "" b in
    let fn = Llvm.insertion_block b |> Llvm.block_parent in
    let grow = Llvm.append_block ctx "" fn and go = Llvm.append_block ctx "" fn in
    let branch = Llvm.build_cond_br full grow go b in
    (* The pool is full far less often than not. *)
    let weights = Llvm.mdnode ctx [| Llvm.mdstring ctx "branch_weights"; Llvm.const_int i32 1; Llvm.const_int i32 2000 |] in
    Llvm.set_metadata branch (Llvm.mdkind_id ctx "prof") weights;
    Llvm.position_at_end grow b;
    flush ctx b c;
    let reserve_type = Llvm.function_type (Llvm.void_type ctx) [| ptr; i64 |] in
    ignore (Llvm.build_call reserve_type (declared m "zane_pool_reserve" reserve_type) [| c.handle; next |] "" b);
    reload ctx b c;
    ignore (Llvm.build_br go b);
    Llvm.position_at_end go b
  end;
  let made = Llvm.build_gep (Llvm.i8_type ctx) (Llvm.build_load ptr c.items "" b) [| at |] "" b in
  let memcpy_type = Llvm.function_type (Llvm.void_type ctx) [| ptr; ptr; i64; Llvm.i1_type ctx |] in
  ignore
    (Llvm.build_call memcpy_type
       (declared m "llvm.memcpy.p0.p0.i64" memcpy_type)
       [| made; node; int size; Llvm.const_int (Llvm.i1_type ctx) 0 |]
       "" b);
  List.iter
    (fun (o, l) ->
      let distance = Llvm.build_trunc (Llvm.build_sub o (Llvm.build_add at (int l) "" b) "" b) i32 "" b in
      let store = Llvm.build_store distance (Llvm.build_gep (Llvm.i8_type ctx) made [| int l |] "" b) b in
      Llvm.set_alignment 1 store)
    links;
  ignore (Llvm.build_store next c.count b);
  at

(* [call]'s instructions, with the count written back before them and the
   slots read again after, when [args] hand them the pool. *)
let around ctx b args call =
  match !current with
  | Some c when handed args ->
      flush ctx b c;
      let v = call () in
      reload ctx b c;
      v
  | _ -> call ()

(* A fresh pool for the handle at [out], where a value needs one, made
   unbounded, since pushes into it go unchecked. *)
let fresh ctx m b out =
  let t = Llvm.function_type (Llvm.void_type ctx) [| Llvm.pointer_type ctx |] in
  ignore (Llvm.build_call t (declared m "zane_pool_new_unbounded" t) [| out |] "" b)
