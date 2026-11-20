(* A local held in a scope's arena whose value folded to a string literal
   bound by a plain [Let], and the scope it leaves empty dropped.

   `lut String=String(".-+*XM")` is a `String`, a type that can own a
   block, so it is held (Build.bind) and its function places a frame for
   the scope that holds it, zeroes it, links it and drains it on each
   call, before the fold has seen that the value is constant bytes, which
   own nothing. A literal never assigned, moved or lent by address needs
   no slot: its reads already read the constant.

   The scope then holds nothing. Regions dropped such scopes before the
   fold, except one a fresh owner passed to a callee that may drop it
   needs (its wants, which are gone by now); a scope whose body makes no
   call but to runtime functions that only read, and to functions given
   nothing that can hold a handle or an address, can need it for no such
   owner, so only those go. *)

open Cgt.Nodes
open Cgt.Traverse


(* Runtime functions that read and check, and take or drop no owner. *)
let reads =
  Cgt.Runtime.[ Array_at; List_at; Out_of_range; Text_equal; Text_hash; Text_find_pair; Text_find_any; Too_deep ]

(* Whether a value of the type can hold a handle or an address: an
   argument that can be an owner moved into the callee. *)
let rec owns (t : Ty.t) =
  match t with
  | Ty.Handle | Ty.Handle16 | Ty.Ptr | Ty.Ref | Ty.Box32 -> true
  | Ty.Struct ts | Ty.Sum ts -> List.exists owns ts
  | Ty.Array (t, _) | Ty.Packed t -> owns t
  | Ty.Void | Ty.I1 | Ty.I8 | Ty.I32 | Ty.I64 | Ty.F32 | Ty.F64 -> false

let func (f : Func.t) =
  (* Locals whose slot is lent, moved out of or stored to. *)
  let barred = Hashtbl.create 16 in
  walk_stats
    (fun e ->
      match e.Expr.node with
      | Expr.Address v -> Hashtbl.replace barred v ()
      | Expr.Take { address = { Expr.node = Expr.Address v; _ }; _ } -> Hashtbl.replace barred v ()
      | _ -> ())
    (function Stat.Assign { place; _ } -> Hashtbl.replace barred place.Expr.local () | _ -> ())
    f.Func.body;
  let freed = Hashtbl.create 4 in
  let body =
    map_stats
      (fun _ -> None)
      (function
        | Stat.Hold { id; scope; value = { Expr.node = Expr.Text _; _ } as value; _ } when not (Hashtbl.mem barred id) ->
            Hashtbl.replace freed scope ();
            Some [ Stat.Let { id; value } ]
        | _ -> None)
      f.Func.body
  in
  if Hashtbl.length freed = 0 then f
  else
    let calls body =
      exists_in body
        ~expr:(fun e ->
          match e.Expr.node with
          | Expr.Runtime { fn; _ } -> not (List.mem fn reads)
          | Expr.Call { args; _ } -> List.exists (fun (a : Expr.t) -> owns a.Expr.ty) args
          | Expr.Call_value _ | Expr.Foreign_call _ -> true
          | _ -> false)
        ~stat:(function Stat.Spawn _ | Stat.Reserve _ -> true | _ -> false)
    in
    let holds id body =
      exists_in body ~expr:(fun _ -> false) ~stat:(function
        | Stat.Hold { scope; _ } | Stat.Reserve { scope; _ } | Stat.Spawn { scope; _ } -> scope = id
        | _ -> false)
    in
    let rec drop (s : Stat.t) =
      match s with
      | Stat.Scope { id; body } when Hashtbl.mem freed id && (not (holds id body)) && not (calls body) ->
          Some (map_stats (fun _ -> None) drop body)
      | _ -> None
    in
    { f with Func.body = map_stats (fun _ -> None) drop body }

let program (p : Program.t) = { p with Program.funcs = List.map func p.Program.funcs }
