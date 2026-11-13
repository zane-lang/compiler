(* Experimental (docs/experiments/goose-comparison): what a function of the
   program being compiled cannot do to the lists it does not own. Emptied
   when a program is lowered and filled by the optimizer's Loop_pushes when
   it runs, so empty in a build that does not optimize; read by codegen
   (Loop_shapes), which makes room before a loop of pushes only when nothing
   else in the loop could take it, and reads a list's items and count once
   before a loop only when nothing in it could change them. A function
   imported without its body is in neither table: its body is in another
   object. *)

open Nodes

(* The functions that cannot change any list's count -- they push to, make
   room in and remove from no list, spawn nothing, call nothing through a
   value or into C that may call back ([c_stays]), and call only such
   functions -- by symbol. *)
let functions : (string, unit) Hashtbl.t = Hashtbl.create 64

(* The functions that cannot change any list's handle outside their own
   frame: nothing in them [changes] one, and they call only such
   functions. *)
let handles : (string, unit) Hashtbl.t = Hashtbl.create 64

(* The functions whose whole body is one push onto the list their first
   argument names (Loop_pushes.push_function), which change no other list. *)
let pushers : (string, unit) Hashtbl.t = Hashtbl.create 8

(* Whether C cannot call into Zane: the program is a whole program whose C
   is given no function value (docs/design/ffi.md F11) and that calls no
   function of another object. C is lent only a list's elements, never its
   handle (F10), so a call into C then changes no list's count or handle. *)
let c_stays = ref false

let rec scalar (t : Ty.t) =
  match t with
  | Ty.Void | Ty.I1 | Ty.I32 | Ty.I64 | Ty.F32 | Ty.F64 -> true
  | Ty.Struct ts | Ty.Sum ts -> List.for_all scalar ts
  | Ty.Array (t, _) | Ty.Packed t -> scalar t
  | Ty.Handle | Ty.Handle16 | Ty.Ptr | Ty.Ref | Ty.Box32 -> false

(* Whether [e] by itself may change a list's handle that it was not built
   from in the statements around it: a call of a function not in [handles],
   through a value, or into C that may call back; a box, an escape, a move
   or a copy, which the runtime makes; or any runtime operation but an
   element's address, its check and [allowed]'s. *)
let changes_expr ?(allowed = fun _ _ -> false) (e : Expr.t) =
  match e.Expr.node with
  | Expr.Call { fn; _ } -> not (Hashtbl.mem handles fn)
  | Expr.Foreign_call _ -> not !c_stays
  | Expr.Call_value _ | Expr.Box _ | Expr.Escape _ | Expr.Take _ | Expr.Copy _ -> true
  | Expr.Runtime { fn = Runtime.List_at | Runtime.Array_at | Runtime.Out_of_range; _ } -> false
  | Expr.Runtime { fn; args } -> not (allowed fn args)
  | _ -> false

(* Whether [s] by itself may: spawn or join, or write a value holding a
   handle anywhere but a local's own slot. *)
let changes_stat (s : Stat.t) =
  match s with
  | Stat.Spawn _ | Stat.Join _ -> true
  | Stat.Assign { place; value } -> place.Expr.deref && not (scalar value.Expr.ty)
  | Stat.Store { value; _ } | Stat.Place { value; _ } | Stat.Overwrite { value; _ } -> not (scalar value.Expr.ty)
  | Stat.Hold { value; _ } -> not (scalar value.Expr.ty)
  | Stat.Reserve { ty; _ } -> not (scalar ty)
  | _ -> false

(* Whether anything in [body] [changes_expr] or [changes_stat]. *)
let changes ?allowed body = Traverse.exists_in body ~expr:(changes_expr ?allowed) ~stat:changes_stat
