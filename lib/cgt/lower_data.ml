(* Lowering's values built from their parts (docs/design/lowering.md): a
   storage primitive's constructor, arrays, structs, a sum's payload, and a
   field-constructor call with the defaults it leaves out. The walk in
   [Lower] is [w]. *)

module T = Tst.Nodes
module S = Tst.Signature
module Tty = Tst.Ty
open Nodes
open State
open Type_layout
open Literals
open Verbs
open Build

(* A member's value on its way into the type [holder] being built: moved
   there, and placed in a block of its own when the member is boxed. *)
let member w st ctx span holder t (e : T.Expr.t) =
  let value = w.moved st ctx span t e in
  if boxed st holder t && not (pooled st t) then ptr (Expr.Box { value; layout = layout st span t }) else value

(* `ArrayRef.fill(n, make)` (generics.md §8.4): a slot this scope holds,
   each element made by calling `make` with its position, counted from 1, in
   order, and moved into place; then the whole array moves out of the slot,
   which is spent, into wherever the call's value goes. *)
let fill w st ctx span (make : T.Expr.t) (t : Tty.t) : Expr.t =
  match (array_of (Tty.strip_mode t), make.T.Expr.ty) with
  | Some (e, n), Tty.Verb fv ->
      let arr = ty st span t in
      let int k = { Expr.node = Expr.Int (Int64.of_int k); ty = Nodes.Ty.I64 } in
      let f = fresh st and slot = fresh st and i = fresh st and made = fresh st in
      let label = fresh st and result = fresh st in
      let v = value_verb "value" fv (value_params span fv) { T.Block.stats = []; span } in
      let fn = { Expr.node = Expr.Local f; ty = Nodes.Ty.Ptr } in
      let index = { Expr.node = Expr.Local i; ty = Nodes.Ty.I64 } in
      let call = Lower_calls.invoke w ~fn st ctx span v [ index ] None in
      let at =
        ptr
          (Expr.Runtime
             {
               fn = Runtime.Array_at;
               args = [ ptr (Expr.Address slot); index; int n; int (stride st span e) ];
             })
      in
      let next = { Expr.node = Expr.Binary { op = Expr.Add; left = index; right = int 1 }; ty = Nodes.Ty.I64 } in
      let whole = layout st span t in
      let body =
        [
          Stat.Let { id = f; value = w.value_of st ctx make };
          Stat.Reserve { id = slot; scope = arena st ctx.scope; ty = arr; layout = whole };
          Stat.Let { id = i; value = int 1 };
          Stat.Repeat
            {
              count = int n;
              body =
                [
                  Stat.Let { id = made; value = call };
                  Stat.Place
                    {
                      address = at;
                      value = { Expr.node = Expr.Local made; ty = call.Expr.ty };
                      layout = layout st span e;
                    };
                  Stat.assign i next;
                ];
            };
          Stat.assign result
            { Expr.node = Expr.Take { address = ptr (Expr.Address slot); layout = whole }; ty = arr };
        ]
      in
      { Expr.node = Expr.Expand { label; body; result = Some result }; ty = arr }
  | _ -> Diagnostic.bug ~span "lowering: `ArrayRef.fill` with the wrong arguments"

(* A string concept's text with values interpolated into it (types.md §2.7,
   §2.8): its fragments and values joined in written order, into a new
   string that owns its bytes. *)
let text w st ctx span (lit : T.Expr.t) : Expr.t =
  let prim = Tst.Intrinsics.prim "String" in
  let handle node = { Expr.node; ty = Nodes.Ty.Handle } in
  match lit.T.Expr.node with
  | T.Expr.Text_lit pieces -> (
      match List.filter (function T.Expr.Fragment "" -> false | _ -> true) pieces with
      | [ T.Expr.Interpolation v ] -> w.moved st ctx span prim v
      | pieces ->
          let part = function
            | T.Expr.Fragment s -> handle (Expr.Text s)
            | T.Expr.Interpolation v -> w.borrow st ctx span v
          in
          let parts = List.map part pieces in
          (* Each join but the last makes a string only the next one reads, so
             this scope holds it, and its drain returns the bytes. *)
          let held value =
            let id = fresh st and label = fresh st and result = fresh st in
            let body = [ bind st ctx.scope span prim id value; Stat.assign result (handle (Expr.Local id)) ] in
            handle (Expr.Expand { label; body; result = Some result })
          in
          let rec join l = function
            | [] -> l
            | r :: rest ->
                let joined = handle (Expr.Runtime { fn = Runtime.Text_join; args = [ l; r ] }) in
                join (if rest = [] then joined else held joined) rest
          in
          join (List.hd parts) (List.tl parts))
  | _ -> Diagnostic.bug ~span "lowering expected a string literal here"

(* A storage primitive's constructor: `Unit` has no storage, a list starts
   empty, and the others embed their literal. An array's literal is its
   elements, each a value moved into its place, in the order written. *)
let primitive w st ctx span spelling args (t : Tty.t) : Expr.t =
  let prefix = "@primitives$" in
  let n = String.length prefix in
  let name =
    if String.length spelling > n && String.sub spelling 0 n = prefix then
      String.sub spelling n (String.length spelling - n)
    else spelling
  in
  match (name, args) with
  | "Unit", [] -> { Expr.node = Expr.Unit; ty = Nodes.Ty.Void }
  (* A new list is empty, and owns no block until its first `push`. *)
  | ("List" | "ListRef"), [ _ ] ->
      { Expr.node = Expr.Runtime { fn = Runtime.List_new; args = [] }; ty = Nodes.Ty.list_handle () }
  | "ArrayRef.fill", [ _; T.Arg.Value make ] -> fill w st ctx span make t
  | ("Array" | "ArrayRef" | "ArrayRef.refs" | "ArrayRef.roaming"), [ T.Arg.Value v ] -> (
      match ((literal_of ctx v).T.Expr.node, array_of (Tty.strip_mode t)) with
      | T.Expr.Array_lit values, Some (e, n) when List.length values = n ->
          let element i v = (i, w.moved st ctx span e v) in
          { Expr.node = Expr.Record (List.mapi element values); ty = ty st span t }
      (* A spawned call's literal, made into its array where it was spawned
         (specialized). *)
      | T.Expr.Var (T.Name_ref.Local l), Some _ -> (
          let lowered = ty st span t in
          let value =
            match lookup ctx span l with
            | Slot id -> { Expr.node = Expr.Local id; ty = lowered }
            | Pointer id -> deref id lowered
            | _ -> Diagnostic.bug ~span "lowering expected an array literal here"
          in
          if owns st span t then
            { value with Expr.node = Expr.Copy { value; layout = layout st span t } }
          else value)
      | _ -> Diagnostic.bug ~span "lowering expected an array literal of the array's length here")
  (* A scalar formatted as text. The runtime returns a String handle that
     owns the bytes it formats. *)
  | "String", [ T.Arg.Value v ] when scalar v.T.Expr.ty ->
      let value = w.expr st ctx v in
      let fn =
        match value.Expr.ty with
        | Nodes.Ty.I32 -> Runtime.Text_i32
        | Nodes.Ty.I64 -> Runtime.Text_i64
        | Nodes.Ty.F32 -> Runtime.Text_f32
        | Nodes.Ty.F64 -> Runtime.Text_f64
        | _ -> Diagnostic.bug ~span "lowering: a non-scalar reached String's scalar constructor"
      in
      { Expr.node = Expr.Runtime { fn; args = [ value ] }; ty = Nodes.Ty.Handle }
  (* A scalar from another scalar (types.md §2.7): the plain constructors
     widen, and the named ones wrap, truncate or round. *)
  | _, [ T.Arg.Value v ] when scalar v.T.Expr.ty ->
      { Expr.node = Expr.Convert (w.expr st ctx v); ty = ty st span t }
  | "String", [ T.Arg.Value v ] when interpolates (literal_of ctx v) -> text w st ctx span (literal_of ctx v)
  | "String.escaped", [ T.Arg.Value v ] when interpolates (literal_of ctx v) -> (
      let lit = literal_of ctx v in
      match lit.T.Expr.node with
      | T.Expr.Text_lit pieces ->
          text w st ctx span { lit with T.Expr.node = T.Expr.Text_lit (escape_pieces pieces) }
      | _ -> Diagnostic.bug ~span "lowering expected a string literal here")
  | _, [ T.Arg.Value v ] -> literal ctx span name v
  | _ -> Diagnostic.bug ~span (Printf.sprintf "lowering: `%s` with the wrong arguments" spelling)

(* A struct built member by member, in the order they were written. One of a
   single member is that member, and an empty one is nothing (L5). *)
let record w st ctx span t (fields : T.Field_value.t list) =
  let lowered = ty st span t in
  let value (f : T.Field_value.t) =
    member w st ctx span t (field_type st span t f.T.Field_value.slot) f.T.Field_value.value
  in
  let members fields =
    List.map (fun (f : T.Field_value.t) -> (member_index st t f.T.Field_value.slot, value f)) fields
  in
  match (lowered, fields) with
  | Nodes.Ty.Void, [] -> { Expr.node = Expr.Unit; ty = Nodes.Ty.Void }
  | Nodes.Ty.Struct ms, _ when List.length ms = List.length fields ->
      { Expr.node = Expr.Record (members fields); ty = lowered }
  | _, [ f ] when collapsed st t -> { (value f) with ty = lowered }
  | _ -> Diagnostic.bug ~span "lowering expected a value for every member here"

(* The local a stored entry is passed through when the constructor is
   expanded where it is called: a parameter of its own, numbered apart from
   the store [id] it names, and typed as the parameter it fills. *)
let named_store st ctx v (p : T.Local.t) (e : T.Expr.t) id =
  let l = { p with T.Local.id = -id } in
  Hashtbl.replace ctx.env l.T.Local.id
    (if by_address st v p then pointer_binding st v p id else Type_layout.slot st p.T.Local.ty id);
  `Arg (T.Arg.Value { e with T.Expr.node = T.Expr.Var (T.Name_ref.Local l); ty = l.T.Local.ty })

(* One entry of a field constructor called out of slot order: the lets that
   store its value as it runs, and what is passed in its slot. A literal
   for a constructor expanded where it is called (L11) is passed as it is,
   with the values interpolated into one captured in its turn. *)
let store_entry w st ctx span v ~out (slot, (e : T.Expr.t)) =
  let p = List.nth v.params slot in
  match p.T.Local.ty with
  | Tty.Concept _ when expands v ->
      let lets, lit = Lower_calls.captured w st ctx span ~into:ctx.env (literal_of ctx e) in
      (slot, lets, `Arg (T.Arg.Value (if lets = [] then e else lit)))
  | _ ->
      let value = Lower_calls.argument w st ctx span v p e in
      let id = fresh st in
      let named =
        if out then named_store st ctx v p e id
        else `Value { Expr.node = Expr.Local id; ty = value.Expr.ty }
      in
      (slot, [ Stat.Let { id; value } ], named)

(* Each value is stored as the constructor takes it, in the order it runs,
   and passed in its slot. A stored value reaches an expanded constructor
   through a local of its own that names the store ([named_store]): an `&T`
   one's store holds the reference already, not a place to mint one from. *)
let construct_reordered w st ctx span v given handler ret =
  let in_slots = List.sort (fun (a, _) (b, _) -> compare a b) given in
  let out =
    Lower_calls.writes_out w st ctx span v (List.map (fun (_, e) -> T.Arg.Value e) in_slots)
  in
  let stored = List.map (store_entry w st ctx span v ~out) given in
  let lets = List.concat_map (fun (_, l, _) -> l) stored in
  let in_slot slot = List.find_map (fun (s, _, a) -> if s = slot then Some a else None) stored in
  let slots =
    List.init (List.length given) (fun slot ->
        match in_slot slot with
        | Some a -> a
        | None -> Diagnostic.bug ~span (Printf.sprintf "lowering: argument slot %d is empty" slot))
  in
  let value =
    if out then
      let arg = function
        | `Arg a -> a
        | `Value _ -> Diagnostic.bug ~span "lowering expected an argument"
      in
      Lower_calls.expand w st ctx span v (List.map arg slots) handler ret
    else
      let value = function
        | `Value a -> a
        | `Arg _ -> Diagnostic.bug ~span "lowering expected a value"
      in
      Lower_calls.invoke w st ctx span v (List.map value slots) handler
  in
  let label = fresh st in
  if value.Expr.ty = Nodes.Ty.Void then
    let body = lets @ [ Stat.Eval value ] in
    { Expr.node = Expr.Expand { label; body; result = None }; ty = value.Expr.ty }
  else
    let result = fresh st in
    let body = lets @ [ Stat.assign result value ] in
    { Expr.node = Expr.Expand { label; body; result = Some result }; ty = value.Expr.ty }

(* types.md §3.3: a field-constructor call is a call to the constructor,
   with each entry's value in its slot and an entry left out given its
   default. The entries run in the order written, then the defaults in
   declaration order. *)
let construct_fields w st ctx span verb (fields : T.Field_value.t list) handler ret =
  match verb with
  | None -> Diagnostic.bug ~span "lowering: a call to a verb it has no body for"
  | Some v ->
      let defaults = Option.value ~default:[] (Hashtbl.find_opt st.defaults v.key) in
      let slots = List.map (fun (f : T.Field_value.t) -> f.T.Field_value.slot) fields in
      let left_out = List.filter (fun (slot, _) -> not (List.mem slot slots)) defaults in
      let written =
        List.map (fun (f : T.Field_value.t) -> (f.T.Field_value.slot, f.value)) fields
      in
      let given = written @ left_out in
      if List.length given <> List.length v.params then
        Diagnostic.bug ~span "lowering expected every entry of a field constructor to be given or defaulted";
      if List.map fst given = List.init (List.length given) Fun.id then
        Lower_calls.call w st ctx span verb
          (List.map (fun (_, e) -> T.Arg.Value e) given)
          handler ret
      else construct_reordered w st ctx span v given handler ret
