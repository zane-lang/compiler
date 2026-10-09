(* A scope's frame (docs/design/lowering.md §9): the runtime's record of the
   scope first, then every slot the scope places and every call it spawns,
   each at an offset fixed here. Every size is known now, so the runtime
   places a whole frame at once when the scope opens, and a slot is an
   address the frame's start plus a constant. *)

open Cgt.Nodes

(* A frame's record, and the header before a spawned call's own frame, as
   runtime/zane_internal.h has them and asserts. *)
let record = 224
let task = 96

(* The guard after a context's range (ZANE_GUARD): a frame no larger is
   stopped by the guard if it does not fit, and a larger one is checked
   before it is placed. *)
let guard = 1 lsl 20

type t = {
  size : int;
  (* Where each slot is, by its local, and each spawned call's header, by
     its task. *)
  offsets : (int, int) Hashtbl.t;
}

let round n a = (n + a - 1) / a * a

(* The frame of scope [id], whose statements are [body]. A slot the scope
   places is placed once per entry, so one under a loop with no scope of its
   own, which would take a new slot each time round, or in a nested scope,
   which places its own, is lowering's mistake. *)
let layout symbol id body =
  let offsets = Hashtbl.create 8 in
  let size = ref record in
  let place key (bytes, align) =
    if align > 16 then Diagnostic.bug (Printf.sprintf "frames: `%s` has a slot aligned past 16" symbol);
    let at = round !size align in
    Hashtbl.replace offsets key at;
    size := at + bytes
  in
  let placed ~again =
    if again then
      Diagnostic.bug
        (Printf.sprintf "frames: `%s` places a slot of arena %%%d under a loop or a nested scope"
           symbol id)
  in
  let rec stat again (s : Stat.t) =
    (match s with
    | Stat.Hold { id = local; scope; value; _ } when scope = id ->
        placed ~again;
        place local (Ty.size_align value.Expr.ty)
    | Stat.Reserve { id = local; scope; ty; _ } when scope = id ->
        placed ~again;
        place local (Ty.size_align ty)
    | Stat.Spawn { task = t; scope; frame; dest; _ } when scope = id ->
        placed ~again;
        let bytes, align = Ty.size_align frame in
        if align > 8 then
          Diagnostic.bug (Printf.sprintf "frames: `%s` spawns a call whose frame is aligned past a word" symbol);
        place t (task + bytes, 8);
        let result = match frame with Ty.Struct (r :: _) -> r | _ -> Ty.Void in
        Option.iter (fun d -> place d (Ty.size_align result)) dest
    | _ -> ());
    let es, bodies = Cgt.stat_parts s in
    let inner = match s with Stat.Repeat _ | Stat.Scope _ -> true | _ -> again in
    List.iter (expr again) es;
    List.iter (List.iter (stat inner)) bodies
  and expr again e =
    let es, bodies = Cgt.expr_parts e in
    List.iter (expr again) es;
    List.iter (List.iter (stat again)) bodies
  in
  List.iter (stat false) body;
  { size = round !size 16; offsets }
