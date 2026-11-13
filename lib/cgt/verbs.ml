(* Lowering's verbs (docs/design/lowering.md): how a verb is keyed, found,
   named and queued, which verbs are written out where they are called (L11),
   and how a function value is called as a verb (L14). *)

module T = Tst.Nodes
module S = Tst.Signature
module Tty = Tst.Ty
open Nodes
open State
open Type_layout

(* A verb's symbol is its declaration as written (Symbol.verb). Asking for
   one queues the verb to be lowered, once. *)
let symbol st (v : verb) =
  match Hashtbl.find_opt st.symbols v.key with
  | Some s -> s
  | None ->
      let s = Symbol.verb ~stamp:st.stamp v.signature v.instance in
      Hashtbl.replace st.symbols v.key s;
      Queue.add v st.pending;
      s

(* L16: the address of a package constant, which a function of its own
   makes the first time it is called and gives from then on. Asking for one
   queues that function to be lowered, once. *)
let constant st decl =
  let c = Hashtbl.find st.constants decl in
  let key = "constant " ^ string_of_int decl in
  if not (Hashtbl.mem st.symbols key) then begin
    Hashtbl.replace st.symbols key c.symbol;
    Queue.add decl st.made
  end;
  { Expr.node = Expr.Call { fn = c.symbol; args = [] }; ty = Nodes.Ty.Ptr }

(* The next number of a function the compiler makes for itself, of the
   kind [count] counts: one more than those made so far. *)
let numbered count =
  incr count;
  !count

(* A verb's key: its declaration's id, with an instance's arguments. *)
let key decl (instance : (Tty.param * Tty.arg) list) =
  match instance with
  | [] -> string_of_int decl
  | args ->
      Printf.sprintf "%d<%s>" decl
        (String.concat ", " (List.map (fun (_, a) -> Tty.arg_to_string a) args))

(* The verb a reference names: a declaration, or the instance its arguments
   pick. *)
let verb_of st id instance = Hashtbl.find_opt st.verbs (key id instance)

(* L11: a verb with a concept parameter -- a block, or a literal it embeds --
   has no function. Each call to it is replaced by its body. *)
let expands (v : verb) =
  List.exists
    (fun (p : T.Local.t) -> match p.T.Local.ty with Tty.Concept _ -> true | _ -> false)
    v.params

(* L11: an expression verb, one whose body is a single expression it
   returns, is written out where it is called too, though it keeps its
   function for every use that needs one: a spawned call, a function value,
   and an object built apart. It declares no abort, and nothing it writes
   out spawns or holds a lambda, whose function is named after the verb it
   is written in. Each verb it calls that is written out counts with its own
   size, and a verb that always expands, or a declared subscript, counts
   with its whole body, so a chain of them is expanded only while it stays
   [most_expanded] nodes or fewer. One that would be written out inside
   itself is called there instead, so its own function writes each call to
   itself out once. *)
let most_expanded = 40

(* The declared verb an expression calls, with its instance, and whether
   it is written out wherever it is used: a declared subscript always is
   (functions.md §2.9). *)
let called (e : T.Expr.t) =
  let declared always (r : T.Verb_ref.t) =
    match r.T.Verb_ref.owner with S.Declared id -> Some (id, r.T.Verb_ref.instance, always) | _ -> None
  in
  match e.T.Expr.node with
  | T.Expr.Call { callee = r; _ }
  | T.Expr.Construct { ctor = r; _ }
  | T.Expr.Construct_fields { ctor = r; _ }
  | T.Expr.Op { impl = r; _ }
  | T.Expr.Flip { impl = r; _ }
  | T.Expr.Coerce { ctor = r; _ } ->
      declared false r
  | T.Expr.Subscript { impl = r; _ } -> declared true r
  | _ -> None

(* Raised while counting a body that is not written out. *)
exception Kept

(* The nodes a body adds where it is written out, counted by [go] with the
   two counters it is given, one for an expression and one for a block:
   each node once, and each verb it writes out with its own size. A spawn
   or a lambda is not written out, and neither is anything over [limit].
   [None] when it is not written out. *)
let rec tally st limit go =
  let total = ref 0 in
  (* The verb [e] calls, if it has one, and whether it always expands. *)
  let callee e =
    let ( let* ) = Option.bind in
    let* id, instance, always = called e in
    let* c = verb_of st id instance in
    Some (c, always)
  in
  let rec count (e : T.Expr.t) =
    incr total;
    (match e.T.Expr.node with T.Expr.Spawn _ | T.Expr.Lambda _ -> raise Kept | _ -> ());
    (match callee e with
    | Some (c, always) -> (
        left_out e c;
        match size st c with
        | Some m -> total := !total + m
        | None -> if always || expands c then raise Kept)
    | None -> ());
    if !total > limit then raise Kept;
    List.iter
      (function
        | Tst.Traverse.Same x -> count x
        | Tst.Traverse.Arm b | Tst.Traverse.Handler b | Tst.Traverse.Block b -> block b
        | Tst.Traverse.Lambda _ -> raise Kept)
      (Tst.Traverse.parts e)
  (* A field constructor's entries left out are given their defaults where
     it is lowered (Lower_data.construct_fields), so they count too. *)
  and left_out (e : T.Expr.t) (c : verb) =
    match e.T.Expr.node with
    | T.Expr.Construct_fields { fields; _ } ->
        let written = List.map (fun (f : T.Field_value.t) -> f.T.Field_value.slot) fields in
        Option.value ~default:[] (Hashtbl.find_opt st.defaults c.key)
        |> List.iter (fun (slot, d) -> if not (List.mem slot written) then count d)
    | _ -> ()
  and block (b : T.Block.t) =
    List.iter
      (fun (s : T.Stat.t) ->
        match s.T.Stat.node with
        | T.Stat.Spawn _ -> raise Kept
        | _ -> List.iter count (Tst.Traverse.stat_exprs s))
      b.T.Block.stats
  in
  try
    go count block;
    Some !total
  with Kept -> None

(* The nodes [v] adds where it is written out: an expression verb's
   expression, or every statement of a verb that always expands, each with
   the verbs it writes out counted in. [None] when it is not written out
   that way, or not within [most_expanded]. *)
and size st (v : verb) =
  match Hashtbl.find_opt st.sizes v.key with
  | Some n -> n
  | None ->
      (* A verb whose size is being counted is not written out in itself. *)
      Hashtbl.replace st.sizes v.key None;
      let n =
        match v.body.T.Block.stats with
        | _ when v.decl < 0 -> None
        | _ when expands v -> tally st most_expanded (fun _ block -> block v.body)
        | [ { T.Stat.node = T.Stat.Return e; _ } ] when Option.is_none v.signature.S.abort ->
            tally st most_expanded (fun count _ -> count e)
        | _ -> None
      in
      Hashtbl.replace st.sizes v.key n;
      n

let inlines st ctx (v : verb) =
  (not (expands v)) && (not (List.mem v.decl ctx.expanding)) && Option.is_some (size st v)

(* L11: a function called in a loop's body is written out there too when
   it is small and calls itself nowhere, so the loop's analyses see what it
   runs: a search that walks a table or a tree, written as a function, is
   then a loop inside the caller's loop, and a `return` in it leaves only
   the copy, as a loop's `break` would. Such a function is a walk. It
   reads what it is given and writes none of it, so no `mut` method is one;
   it declares no abort, is no foreign verb, and nothing it writes out spawns
   or holds a lambda, as for an expression verb; its size counts every
   statement with the verbs it writes out, and is at most [most_walked]
   nodes. Inside a walk, nothing is written out as a walk again (State.loop),
   so a loop writes out one level of what it calls. *)
let most_walked = 120

(* Whether [v] reaches a call to itself through the declared verbs its body
   calls, those they call, and so on. *)
let recursive st (v : verb) =
  let seen = Hashtbl.create 16 in
  let rec visit (c : verb) =
    if not (Hashtbl.mem seen c.key) then begin
      Hashtbl.replace seen c.key ();
      body c
    end
  and body (c : verb) =
    let rec expr (e : T.Expr.t) =
      (match called e with
      | Some (id, instance, _) -> (
          match verb_of st id instance with
          | Some d when d.key = v.key -> raise Exit
          | Some d -> visit d
          | None -> ())
      | None -> ());
      List.iter
        (function
          | Tst.Traverse.Same x -> expr x
          | Tst.Traverse.Arm b | Tst.Traverse.Handler b | Tst.Traverse.Block b -> block b
          | Tst.Traverse.Lambda _ -> ())
        (Tst.Traverse.parts e)
    and block (b : T.Block.t) =
      List.iter (fun s -> List.iter expr (Tst.Traverse.stat_exprs s)) b.T.Block.stats
    in
    block c.body
  in
  try
    body v;
    false
  with Exit -> true

(* Whether a value of [t] holds an address anywhere in it: a list's
   handle, a reference, a box. *)
let rec holds_address (t : Nodes.Ty.t) =
  match t with
  | Nodes.Ty.Handle | Nodes.Ty.Handle16 | Nodes.Ty.Ptr | Nodes.Ty.Ref | Nodes.Ty.Box32 -> true
  | Nodes.Ty.Packed t | Nodes.Ty.Array (t, _) -> holds_address t
  | Nodes.Ty.Struct ts | Nodes.Ty.Sum ts -> List.exists holds_address ts
  | Nodes.Ty.Void | Nodes.Ty.I1 | Nodes.Ty.I32 | Nodes.Ty.I64 | Nodes.Ty.F32 | Nodes.Ty.F64 -> false

(* Whether [v] is given anything it can read memory through, a parameter
   that holds an address or an owner it borrows, and takes no owner. A function that is given
   only numbers computes rather than walks, and is what memoization may
   give a table (docs/design/memoization.md M1), which a copy written out
   would not consult. *)
let reads_through st (v : verb) =
  (* A walk takes nothing: a callee given an owner it may drop keeps its
     function, whose arena Regions decides (lowering.md §9). *)
  (not (List.exists (fun (p : T.Local.t) -> roaming st p.T.Local.ty) v.params))
  && List.exists
    (fun (p : T.Local.t) ->
      owned st p.T.Local.ty || Tty.is_ref p.T.Local.ty
      || holds_address (ty st p.T.Local.span p.T.Local.ty))
    v.params

(* [v]'s size where a loop's body writes it out as a walk, or [None]. *)
let walk_size st (v : verb) =
  match Hashtbl.find_opt st.walks v.key with
  | Some n -> n
  | None ->
      let n =
        if
          v.decl < 0 || expands v || v.signature.S.is_mut
          || Option.is_some v.signature.S.abort
          || Hashtbl.mem st.foreign_verbs v.key
          || Option.is_some (size st v)
          || (not (reads_through st v))
          || recursive st v
        then None
        else tally st most_walked (fun _ block -> block v.body)
      in
      Hashtbl.replace st.walks v.key n;
      n

(* Whether a direct call to [v] here writes it out as a walk. *)
let walks st ctx (v : verb) =
  ctx.loop = Inside && (not (List.mem v.decl ctx.expanding)) && Option.is_some (walk_size st v)

(* Whether a direct call to [v] is replaced by its body (L11). *)
let written_out st ctx v = expands v || inlines st ctx v || walks st ctx v

(* L6: a `mut` method's subject, a reference-type subject, and a borrowed
   reference-type argument are passed as the address of the caller's place;
   the caller stays a full owner (memory.md §2.9). A `^T` argument is the
   moved value itself. An array given to a foreign verb is lent where it is
   too, whatever its size, so C reads the caller's array (docs/design/ffi.md
   F10). *)
let rec by_address st (v : verb) (p : T.Local.t) =
  (v.signature.S.is_mut && p.T.Local.name = "this")
  || (owned st p.T.Local.ty && not (Tty.is_roaming p.T.Local.ty))
  || (Hashtbl.mem st.foreign_verbs v.key && Option.is_some (array_of (Tty.strip_mode p.T.Local.ty)))
  || viewed st v p

(* Experimental: a borrowed parameter of a pooled variant is the address of
   its node (Type_layout.pooled), unless the verb returns it as a field of
   what it makes: that one is passed whole, as without pooling, so a
   temporary moves into the new value rather than being copied out of its
   node. A borrowed struct a pooled variant's payload is would be inside a
   node or not, and the prototype takes neither. A `mut` method's subject
   is the caller's place, which the body may write a new root into. *)
and viewed st (v : verb) (p : T.Local.t) =
  let t = p.T.Local.ty in
  if (not (Tty.is_ref t)) && (not (Tty.is_roaming t)) && cycle_struct st t then
    refuse p.T.Local.span "pooled variants: a borrowed parameter of a pooled variant's payload";
  (not (v.signature.S.is_mut && p.T.Local.name = "this"))
  && (not (Tty.is_ref t))
  && (not (Tty.is_roaming t))
  && pooled st t
  && not (stored v p)

(* Whether [v]'s body returns [p] itself as a field of a value it makes. *)
and stored (v : verb) (p : T.Local.t) =
  let field (f : T.Field_value.t) =
    match f.T.Field_value.value.T.Expr.node with
    | T.Expr.Var (T.Name_ref.Local l) -> l.T.Local.id = p.T.Local.id
    | _ -> false
  in
  List.exists
    (fun (s : T.Stat.t) ->
      match s.T.Stat.node with
      | T.Stat.Return { T.Expr.node = T.Expr.Init fields; _ } -> List.exists field fields
      | _ -> false)
    v.body.T.Block.stats

(* The binding of a parameter [by_address] passes. *)
let pointer_binding st v (p : T.Local.t) id = if viewed st v p then Node id else Pointer id

(* L14: a function value is called as a verb of its type would be, so its
   type gives the verb it is called as: the subject first, named `this`, as a
   lambda's own is. A function value's subject is always lent by its
   address, since a lambda that does not declare `mut` may be held by a
   `mut` function type (functions.md §7.2), and one convention serves both. *)
let value_verb key (fv : Tty.verb) params body =
  let signature =
    {
      S.owner = S.Intrinsic "<lambda>";
      name = "lambda";
      home = S.Namespace "lambda";
      kind = S.Function;
      generics = [];
      params = [];
      ret = fv.Tty.ret;
      abort = fv.Tty.abort;
      is_mut = true;
    }
  in
  { decl = -1; key; instance = []; signature; params; body; literals = [] }

let value_params span (fv : Tty.verb) =
  let local name ty = { T.Local.id = -1; name; ty; span } in
  Option.to_list (Option.map (local "this") fv.Tty.this_)
  @ List.mapi (fun i t -> local (string_of_int i) t) fv.Tty.params
