(* Lowering's calls (docs/design/lowering.md): subscripts, calls to a
   verb's function or through a function value, the arguments they are
   passed, and a verb expanded where it is called. The walk in [Lower] is
   [w]. *)

module T = Tst.Nodes
module S = Tst.Signature
module Tty = Tst.Ty
open Nodes
open State
open Type_layout
open Literals
open Verbs
open Outcome
open Build

(* The address of an element (functions.md §2.9): a list's or an array's,
   checked against its length, or what a declared subscript's body names,
   with `this` bound to the target's place. *)
let subscript w st ctx span (target : T.Expr.t) (impl : T.Verb_ref.t) args =
  let int n = { Expr.node = Expr.Int (Int64.of_int n); ty = Nodes.Ty.I64 } in
  match (impl.owner, args) with
  | S.Intrinsic "@primitives$[]", [ index ] -> (
      let ty = Tty.strip_mode target.T.Expr.ty in
      match (element ty, array_of ty) with
      | Some t, _ ->
          ptr
            (Expr.Runtime
               {
                 fn = Runtime.List_at;
                 args =
                   [
                     w.lend st ctx span target;
                     w.borrow st ctx span index;
                     int (stride st span t);
                   ];
               })
      | None, Some (t, n) ->
          let array = w.lend st ctx span target in
          let index = w.borrow st ctx span index in
          ptr
            (Expr.Runtime
               { fn = Runtime.Array_at; args = [ array; index; int n; int (stride st span t) ] })
      | None, None -> Diagnostic.bug ~span "lowering: an intrinsic subscript of something not a list or an array")
  | S.Declared id, _ -> (
      match verb_of st id impl.instance with
      | Some ({ params = this :: rest; body = { stats = [ { node = T.Stat.Return e; _ } ]; _ }; _ }
             as v)
        when List.length rest = List.length args ->
          let env = Hashtbl.create 4 in
          let at = fresh st in
          Hashtbl.replace env this.T.Local.id (Pointer at);
          let binds =
            Stat.Let { id = at; value = w.lend st ctx span target }
            :: List.map2
                 (fun (p : T.Local.t) a ->
                   let id = fresh st in
                   Hashtbl.replace env p.T.Local.id (slot st p.T.Local.ty id);
                   Stat.Let { id; value = w.borrow st ctx span a })
                 rest args
          in
          let inner = { ctx with env; expanding = v.decl :: ctx.expanding } in
          let label = fresh st in
          let result = fresh st in
          let place =
            match w.addr st inner span e with
            | Some p -> p
            | None -> Diagnostic.bug ~span "lowering expected a subscript's body to name a place"
          in
          ptr
            (Expr.Expand
               { label; body = binds @ [ Stat.assign result place ]; result = Some result })
      | _ -> Diagnostic.bug ~span "lowering: a declared subscript with no single place to name")
  | _ -> Diagnostic.bug ~span "lowering: a subscript of no owner it knows"

(* Experimental pooled variants: whether [v]'s function builds its pooled
   result in a pool its caller gives it, as one more parameter after its
   own, and returns where the result's top node is in that pool
   (Lower.into). A verb written out where it is called, or one that can
   abort or exit, returns its result as before. *)
let pours st span (v : verb) =
  v.decl >= 0
  && pooled st (Tty.strip_mode v.signature.S.ret)
  && (not (expands v))
  && Option.is_none (size st v)
  && plain (outcome st span v)

let rec call w st ctx span verb args handler ret : Expr.t =
  match verb with
  | None -> Diagnostic.bug ~span "lowering: a call to a verb it has no body for"
  | Some v -> (
      match passed v args with
      | T.Arg.Value subject :: rest when v.signature.S.is_mut && subscripted subject ->
          located_last w st ctx span v subject rest handler ret
      | args -> plain_call w st ctx span v args handler ret)

and plain_call w st ctx span v args handler ret =
  if writes_out w st ctx span v args then expand w st ctx span v args handler ret
  else invoke w st ctx span v (arguments w st ctx span v args) handler

(* Whether this call to [v] is replaced by its body (L11). An expression
   verb's call is not when it gives a fresh value to a value parameter that
   owns blocks: written out, the value would be held in a slot of the
   caller's and copied wherever the body keeps it, where the verb's function
   takes it instead (Regions.taken_params). *)
and writes_out w st ctx span v args =
  expands v
  || inlines st ctx v
     && List.length args = List.length v.params
     && not
          (List.exists2
             (fun (p : T.Local.t) a ->
               match a with
               | T.Arg.Value e ->
                   p.T.Local.name <> "this"
                   && (not (owned st p.T.Local.ty))
                   && (not (Tty.is_ref p.T.Local.ty))
                   && (not (roaming st p.T.Local.ty))
                   && held st span p.T.Local.ty
                   && not (w.is_place e)
               | T.Arg.Block _ -> false)
             v.params args)

(* A call through a function value, which is read before its arguments. *)
and call_value w st ctx span (callee : T.Expr.t) args handler =
  match Tty.strip_mode callee.T.Expr.ty with
  | Tty.Verb fv -> (
      let v = value_verb "value" fv (value_params span fv) { T.Block.stats = []; span } in
      let (fn : Expr.t) = w.value_of st ctx callee in
      match args with
      | T.Arg.Value subject :: rest
        when fv.Tty.is_mut && Option.is_some fv.Tty.this_ && subscripted subject ->
          (* The function value is read first, as it is written. *)
          let id = fresh st in
          let read = { Expr.node = Expr.Local id; ty = fn.Expr.ty } in
          let lets, args = held_last w ~direct:false st ctx span v subject rest in
          held_in st
            (Stat.Let { id; value = fn } :: lets)
            (invoke w ~fn:read st ctx span v (arguments w ~direct:false st ctx span v args) handler)
      | _ -> invoke w ~fn st ctx span v (arguments w ~direct:false st ctx span v args) handler)
  | _ -> Diagnostic.bug ~span "lowering expected a function value here"

(* A `!` call whose subject is reached through a subscript (memory.md §2.12):
   the subject's operands run first, then the arguments, each held in a slot
   of its own in written order, and only then is the subject located, so an
   argument that moves the list the subject is an element of moves it before
   the call finds where the element is. *)
and located_last w st ctx span v subject rest handler ret =
  let lets, args = held_last w st ctx span v subject rest in
  held_in st lets (plain_call w st ctx span v args handler ret)

(* The subject's operands pinned and each argument held, as [located_last]
   needs them, for any call form that runs a `!` call on a subscripted
   subject: the statements, and the arguments to pass. *)
and held_last w ?direct st ctx span v subject rest =
  let pins, subject = pinned w st ctx span subject in
  let held =
    match v.params with
    | _ :: params when List.length params = List.length rest ->
        List.map2 (held_argument w ?direct st ctx span v) params rest
    | _ -> Diagnostic.bug ~span "lowering: a `!` call with the wrong arguments"
  in
  (pins @ List.concat_map fst held, T.Arg.Value subject :: List.map snd held)

(* One argument for parameter [p], run now and held in a slot of its own:
   the statement that holds it, and the argument that reads it back. A
   literal or a block an expanded verb takes stands for itself, so it is
   passed on as it is. *)
and held_argument w ?direct st ctx span v (p : T.Local.t) a =
  match (a, p.T.Local.ty) with
  (* An array literal's elements are values, so the array is made now, as
     [expand] would make it where it binds the parameter. *)
  | T.Arg.Value e, Tty.Concept (Tty.Array_lit (t, n)) when expands v && is_array_lit (literal_of ctx e) ->
      let arr = array_type t n in
      let value = w.primitive st ctx span "@primitives$Array" [ a ] arr in
      let id = fresh st in
      let l = { p with T.Local.id = -id } in
      Hashtbl.replace ctx.env l.T.Local.id (slot st arr id);
      let hold =
        if held st span arr then Stat.Hold { id; scope = arena st ctx.scope; value; layout = layout st span arr }
        else Stat.Let { id; value }
      in
      ([ hold ], T.Arg.Value { e with T.Expr.node = T.Expr.Var (T.Name_ref.Local l) })
  | T.Arg.Value e, Tty.Concept _ when expands v ->
      let lets, lit = captured w st ctx span ~into:ctx.env (literal_of ctx e) in
      if lets = [] then ([], T.Arg.Value e) else (lets, T.Arg.Value lit)
  | T.Arg.Value e, _ ->
      let value = argument w ?direct st ctx span v p e in
      let id = fresh st in
      let l = { p with T.Local.id = -id } in
      Hashtbl.replace ctx.env l.T.Local.id
        (if by_address st v p then pointer_binding st v p id else slot st p.T.Local.ty id);
      let read = { e with T.Expr.node = T.Expr.Var (T.Name_ref.Local l) } in
      ([ Stat.Let { id; value } ], T.Arg.Value read)
  | (T.Arg.Block _ as b), _ -> ([], b)

(* A string literal given to a concept parameter, with each value
   interpolated into it evaluated where the literal is written, in written
   order, and a copy of it held in a slot of this scope (types.md §2.8): the
   statements that hold them, and the literal reading the slots instead.
   The slots are named in [into] too, where the body reads the literal. A
   literal passed on from a parameter already reads its slots, which [into]
   is given as they are. *)
and captured w st ctx span ~into (lit : T.Expr.t) =
  match lit.T.Expr.node with
  | T.Expr.Text_lit pieces when interpolates lit ->
      let prim = Tst.Intrinsics.prim "String" in
      let piece = function
        | T.Expr.Interpolation { T.Expr.node = T.Expr.Var (T.Name_ref.Local l); _ } as p
          when l.T.Local.name = interpolated_name ->
            Hashtbl.replace into l.T.Local.id (lookup ctx span l);
            ([], p)
        | T.Expr.Interpolation v ->
            let id = fresh st in
            let l = { T.Local.id = -id; name = interpolated_name; ty = prim; span = v.T.Expr.span } in
            let b = slot st prim id in
            Hashtbl.replace ctx.env l.T.Local.id b;
            Hashtbl.replace into l.T.Local.id b;
            let hold = Build.bind st ctx.scope span prim id (w.moved st ctx span prim v) in
            ([ hold ], T.Expr.Interpolation { v with T.Expr.node = T.Expr.Var (T.Name_ref.Local l); ty = prim })
        | p -> ([], p)
      in
      let held = List.map piece pieces in
      (List.concat_map fst held, { lit with T.Expr.node = T.Expr.Text_lit (List.map snd held) })
  | _ -> ([], lit)

(* [lets], then [value], as one expression. *)
and held_in st lets (value : Expr.t) =
  let label = fresh st in
  let body, result =
    if value.Expr.ty = Nodes.Ty.Void then (lets @ [ Stat.Eval value ], None)
    else
      let result = fresh st in
      (lets @ [ Stat.assign result value ], Some result)
  in
  { Expr.node = Expr.Expand { label; body; result }; ty = value.Expr.ty }

(* Whether a place is reached through a subscript, whose element a list
   that grows would move. *)
and subscripted (e : T.Expr.t) =
  match e.T.Expr.node with
  | T.Expr.Subscript _ -> true
  | T.Expr.Field { target; _ } | T.Expr.Case_read { target; _ } -> subscripted target
  | _ -> false

(* A place's operands, its subscripts' indices, run now into slots of their
   own in written order, and the place rewritten to read them: what runs
   after them no longer changes which element is meant, and where that
   element is is found when the place is located. *)
and pinned w st ctx span (e : T.Expr.t) : Stat.t list * T.Expr.t =
  match e.T.Expr.node with
  | T.Expr.Field ({ target; _ } as f) ->
      let pins, target = pinned w st ctx span target in
      (pins, { e with T.Expr.node = T.Expr.Field { f with target } })
  | T.Expr.Subscript ({ target; args; _ } as s) ->
      let pins, target = pinned w st ctx span target in
      let held =
        List.map
          (fun (a : T.Expr.t) ->
            let id = fresh st in
            let l = { T.Local.id = -id; name = "index"; ty = a.T.Expr.ty; span = a.T.Expr.span } in
            Hashtbl.replace ctx.env l.T.Local.id (slot st a.T.Expr.ty id);
            let read = { a with T.Expr.node = T.Expr.Var (T.Name_ref.Local l) } in
            (Stat.Let { id; value = w.borrow st ctx span a }, read))
          args
      in
      let args = List.map snd held in
      (pins @ List.map fst held, { e with T.Expr.node = T.Expr.Subscript { s with target; args } })
  | _ -> ([], e)

(* A type written where a value goes, or a number given to an explicit
   number parameter, picks the instance, and an instance takes no parameter
   for it (generics.md §5.3). *)
and passed (v : verb) args =
  let bound =
    if List.length v.signature.S.params = List.length args then
      List.map (fun (p : S.param) -> Option.is_some p.S.binds) v.signature.S.params
    else List.map (fun _ -> false) args
  in
  List.combine bound args
  |> List.filter_map (fun (bound, arg) ->
         match arg with
         | T.Arg.Value { T.Expr.node = T.Expr.Type_arg _; _ } -> None
         | _ -> if bound then None else Some arg)

and arguments w ?direct st ctx span v args =
  List.map2
    (fun (p : T.Local.t) arg ->
      match arg with
      | T.Arg.Value a -> argument w ?direct st ctx span v p a
      | T.Arg.Block _ -> Diagnostic.bug ~span "lowering: a block argument to a verb it does not expand")
    v.params args

(* An argument as the callee takes it (L6): a place it may write, or a
   borrowed owner, is lent by its address, a reference is minted or copied,
   a `^T` argument is moved, and a value is borrowed.

   A fresh owner moved into a `^T` parameter is made in this block's
   region. A callee that drops it leaves its blocks there (memory.md §3.5),
   so they go when this block drains, as they would in the block's own
   scope, rather than piling up in an enclosing one for as long as a loop
   runs. The block keeps an arena for that only when the callee can drop
   the owner, which Regions decides; a call through a function value, and a
   verb expanded here, which has no function of its own, can always. *)
and argument w ?(direct = true) st ctx span v (p : T.Local.t) a =
  if viewed st v p then w.view st ctx span a
  else if by_address st v p then w.lend st ctx span a
  else if Tty.is_ref p.T.Local.ty then w.reference_to st ctx span a
  else if roaming st p.T.Local.ty then begin
    (if held st span p.T.Local.ty && not (w.is_place a) then
       if (not direct) || written_out st ctx v then
         (* A callee Regions cannot see may drop it, so the arena stays. *)
         ctx.scope.wants <- (dropping, -1) :: ctx.scope.wants
       else
         let same (q : T.Local.t) = q.T.Local.id = p.T.Local.id in
         let index = Option.value ~default:(-1) (List.find_index same v.params) in
         ctx.scope.wants <- (symbol st v, index) :: ctx.scope.wants);
    w.moved st ctx span p.T.Local.ty a
  end
  else w.borrow st ctx span a

(* L12. A call that can end more than one way is switched on how it ended:
   done gives its result, aborted runs its handler, or the abort of the
   `match` it flows out of, and an exit ends this invocation too. The call
   is to [v]'s function, or through [fn], a function value's address. *)
and invoke w ?fn st ctx span v args handler =
  if pours st span v then begin
    if Option.is_some fn then refuse span "pooled variants: a function value that returns one";
    poured st span v args
  end
  else invoked w ?fn st ctx span v args handler

(* A call to a function that [pours] its result, given a new pool of its
   own to build it in. *)
and poured st span v args =
  let handle = ty st span (Tty.strip_mode v.signature.S.ret) in
  let h = fresh st and label = fresh st and result = fresh st in
  let address = ptr (Expr.Address h) in
  let body =
    [
      Stat.Let { id = h; value = { Expr.node = Expr.Runtime { fn = Runtime.List_new; args = [] }; ty = handle } };
      Stat.Eval { Expr.node = Expr.Runtime { fn = Runtime.Pool_new; args = [ address ] }; ty = Nodes.Ty.Void };
      Stat.Eval { Expr.node = Expr.Call { fn = symbol st v; args = args @ [ address ] }; ty = Nodes.Ty.I64 };
      Stat.assign result { Expr.node = Expr.Local h; ty = handle };
    ]
  in
  { Expr.node = Expr.Expand { label; body; result = Some result }; ty = handle }

and invoked w ?fn st ctx span v args handler =
  let o = outcome st span v in
  let call =
    match fn with
    | Some fn -> Expr.Call_value { fn; args }
    | None -> Expr.Call { fn = symbol st v; args }
  in
  let value = { Expr.node = call; ty = returned o } in
  if plain o then value
  else
    let label = fresh st in
    let result = if o.ok = Nodes.Ty.Void then None else Some (fresh st) in
    let id = fresh st in
    let source = { Expr.node = Expr.Local id; ty = value.Expr.ty } in
    let payload index t = { Expr.node = Expr.Payload { value = source; index }; ty = t } in
    let on_abort =
      match handler with
      | Some h -> Lower_match.handle w ?dropped:v.signature.S.abort st ctx h label result
      | None -> ctx.abort
    in
    let finished =
      if o.ok = Nodes.Ty.Void then [ (done_, [ Stat.Leave label ]) ]
      else [ (done_, leave label result (payload done_ o.ok)) ]
    in
    let failed =
      match o.aborts with Some a -> [ (aborted, on_abort span (payload aborted a)) ] | None -> []
    in
    let left = if o.exit_ then [ (exited, ctx.finish span) ] else [] in
    let cases = finished @ failed @ left in
    let body = [ Stat.Let { id; value }; Stat.Switch { value = source; cases } ] in
    { Expr.node = Expr.Expand { label; body; result }; ty = o.ok }

(* L11. A parameter is bound to what it stands for in the body: a block
   argument to its code, a literal to itself, the subject or a borrowed
   owner to the caller's place, a `^T` argument to a slot this scope holds
   the moved value in, and any other argument to a new slot holding its
   value (L6). *)
and expand w st ctx span v args handler ret =
  if List.mem v.decl ctx.expanding then
    Diagnostic.bug ~span (Printf.sprintf "lowering: `%s` expands into itself" v.signature.S.name);
  if List.length args <> List.length v.params then
    Diagnostic.bug ~span "lowering expected an argument for every parameter";
  let env = Hashtbl.create 8 in
  let bind (p : T.Local.t) b = Hashtbl.replace env p.T.Local.id b in

  let binds =
    List.concat
      (List.map2
         (fun (p : T.Local.t) arg ->
           match (arg, p.T.Local.ty) with
           | T.Arg.Block block, _ ->
               bind p (Code { block; ctx });
               []
           | T.Arg.Value a, Tty.Concept Tty.Block -> (
               match a.T.Expr.node with
               | T.Expr.Var (T.Name_ref.Local l) -> (
                   match lookup ctx span l with
                   | Code c ->
                       bind p (Code c);
                       []
                   | _ -> Diagnostic.bug ~span "lowering expected a block here")
               | _ -> Diagnostic.bug ~span "lowering expected a block here")
           (* An array literal's elements are values the caller's code
              names, so the array is made here, where the call is written,
              and the parameter names its slot. *)
           | T.Arg.Value a, Tty.Concept (Tty.Array_lit (t, n)) when is_array_lit (literal_of ctx a)
             ->
               let arr = array_type t n in
               let value = w.primitive st ctx span "@primitives$Array" [ arg ] arr in
               let id = fresh st in
               bind p (slot st arr id);
               if held st span arr then
                 let layout = layout st span arr in
                 [ Stat.Hold { id; scope = arena st ctx.scope; value; layout } ]
               else [ Stat.Let { id; value } ]
           (* A literal stands for itself. A spawned call's array literal is
              a value in a slot by now (specialized), which the parameter
              names too. *)
           | T.Arg.Value a, Tty.Concept _ -> (
               let lit = literal_of ctx a in
               match lit.T.Expr.node with
               | T.Expr.Var (T.Name_ref.Local l) -> (
                   match lookup ctx span l with
                   | (Slot _ | Pointer _) as b ->
                       bind p b;
                       []
                   | _ ->
                       bind p (Literal lit);
                       [])
               | _ ->
                   let lets, lit = captured w st ctx span ~into:env lit in
                   bind p (Literal lit);
                   lets)
           | ( T.Arg.Value { T.Expr.node = T.Expr.Var (T.Name_ref.Local l); T.Expr.ty = at; _ },
               _ )
             when (p.T.Local.name = "this" || (owned st p.T.Local.ty && not (roaming st p.T.Local.ty)))
                  && (not (viewed st v p))
                  && not (Tty.is_ref at) -> (
               match lookup ctx span l with
               | (Slot _ | Pointer _) as b ->
                   bind p b;
                   []
               | Future { settle; at = Some at } ->
                   let id = fresh st in
                   bind p (Pointer id);
                   settle () @ [ Stat.Let { id; value = at } ]
               | _ -> Diagnostic.bug ~span "lowering expected a place here")
           (* A verb that writes none of its parameters reads a local it is
              given where the caller keeps it: nothing else in the call
              writes what the call borrows (memory.md §2.9.1), and nothing
              the body runs can. *)
           | ( T.Arg.Value { T.Expr.node = T.Expr.Var (T.Name_ref.Local l); T.Expr.ty = at; _ },
               _ )
             when (not v.signature.S.is_mut)
                  && (not (Tty.is_ref at))
                  && (not (Tty.is_ref p.T.Local.ty))
                  && (not (roaming st p.T.Local.ty))
                  && (not (viewed st v p))
                  && match lookup ctx span l with Slot _ | Pointer _ -> true | _ -> false ->
               bind p (lookup ctx span l);
               []
           (* A pooled variant is lent as its node (Type_layout.pooled). *)
           | T.Arg.Value a, _ when viewed st v p ->
               let value = w.view st ctx span a in
               let id = fresh st in
               bind p (Node id);
               [ Stat.Let { id; value } ]
           (* Any other place the body may write, or that it borrows, is lent
              by its address. *)
           | T.Arg.Value a, _
             when p.T.Local.name = "this" || (owned st p.T.Local.ty && not (roaming st p.T.Local.ty)) ->
               let value = w.lend st ctx span a in
               let id = fresh st in
               bind p (Pointer id);
               [ Stat.Let { id; value } ]
           (* A taken owner is moved into a slot of its own, which this scope
              holds, so it dies with the scope unless the body moves it on. *)
           | T.Arg.Value a, _ when roaming st p.T.Local.ty ->
               let value = w.moved st ctx span p.T.Local.ty a in
               let id = fresh st in
               bind p (slot st p.T.Local.ty id);
               [ Build.bind st ctx.scope span p.T.Local.ty id value ]
           | T.Arg.Value a, _ ->
               let value =
                 if Tty.is_ref p.T.Local.ty then w.reference_to st ctx span a
                 else w.borrow st ctx span a
               in
               let id = fresh st in
               bind p (slot st p.T.Local.ty id);
               [ Stat.Let { id; value } ])
         v.params args)
  in
  let t = ty st span ret in
  let label = fresh st in
  let result = if t = Nodes.Ty.Void then None else Some (fresh st) in
  (* An exit in the body ends the invocation the call was written in, and
     one that body calls ends the expansion (control-flow.md §4.2). *)
  let inner =
    {
      env;
      exit = Leave { label; result; ret };
      expanding = v.decl :: ctx.expanding;
      abort =
        (match handler with
        | Some h -> Lower_match.handle w ?dropped:v.signature.S.abort st ctx h label result
        | None -> ctx.abort);
      resolve = None;
      finish = no_block;
      exit_call = ctx.finish;
      scope = ctx.scope;
    }
  in
  (* A body that only returns a value is that value, unless the value names
     the expansion, as an owner it moves out of the expansion does. *)
  let named value =
    Traverse.exists_in [ Stat.Eval value ]
      ~expr:(fun e -> match e.Expr.node with Expr.Escape { exit; _ } -> exit = Some label | _ -> false)
      ~stat:(function Stat.Leave l -> l = label | _ -> false)
  in
  match binds @ w.block st inner v.body with
  | [ Stat.Assign { place = { local; path = []; deref = false; _ }; value }; Stat.Leave l ]
    when Some local = result && l = label && not (named value) ->
      value
  | [ Stat.Eval value; Stat.Leave l ] when result = None && l = label && not (named value) -> value
  (* So is one that binds an argument and returns it, as a constructor that
     wraps its argument does. *)
  | [
      Stat.Let { id; value };
      Stat.Assign { place = { local; path = []; deref = false; _ }; value = { Expr.node = Expr.Local x; _ } };
      Stat.Leave l;
    ]
    when x = id && Some local = result && l = label && not (named value) ->
      value
  | body -> { Expr.node = Expr.Expand { label; body; result }; ty = t }
