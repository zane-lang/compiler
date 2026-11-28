(* The checks of a call marked `comptime` (effects.md §5.6) that the tree
   settles, made by [Check.comptime] on the call it typed. The evaluator
   checks the call's writes and reads when it evaluates the call
   (docs/design/comptime.md). *)

open Env
module T = Nodes

(* The result is built into the program as a constant, so it is a value
   type: no reference, capability or handle crosses into the program
   (memory.md §2.10). A type that still names a parameter is checked in each
   instance instead. *)
let result env span (t : Ty.t) =
  if (not (Ty.contains_error t)) && Ty.free_params t = [] && not (Type_decls.is_value env t) then
    error env span
      (Printf.sprintf
         "a `comptime` call's result is built into the program, so it must be a value type, and \
          %s is not"
         (quote (Ty.to_string t)))

(* Each local bound inside [e]: a lambda's parameters, a handler's binder,
   and the locals the blocks in it declare. *)
let bound_inside (e : T.Expr.t) =
  let bound = Hashtbl.create 8 in
  let add (l : T.Local.t) = Hashtbl.replace bound l.T.Local.id () in
  let rec expr (e : T.Expr.t) =
    (match e.T.Expr.node with
    | T.Expr.Lambda { params; _ } -> List.iter add params
    | T.Expr.Call { handler = Some h; _ }
    | T.Expr.Call_value { handler = Some h; _ }
    | T.Expr.Construct { handler = Some h; _ }
    | T.Expr.Construct_fields { handler = Some h; _ }
    | T.Expr.Op { handler = Some h; _ }
    | T.Expr.Flip { handler = Some h; _ }
    | T.Expr.Case_read { handler = h; _ } ->
        Option.iter add h.T.Handler.binder
    | T.Expr.Match { arms; handler; _ } ->
        Option.iter (fun (h : T.Handler.t) -> Option.iter add h.T.Handler.binder) handler;
        let pattern (p : T.Pattern.t) = Option.iter add p.T.Pattern.binder in
        List.iter (fun (a : T.Arm.t) -> List.iter pattern a.T.Arm.patterns) arms
    | _ -> ());
    List.iter part (Traverse.parts e)
  and part = function
    | Traverse.Same e -> expr e
    | Traverse.Arm b | Traverse.Handler b | Traverse.Block b | Traverse.Lambda b -> block b
  and block (b : T.Block.t) = List.iter stat b.T.Block.stats
  and stat (s : T.Stat.t) =
    (match s.T.Stat.node with T.Stat.Let { local; _ } -> add local | _ -> ());
    List.iter expr (Traverse.stat_exprs s)
  in
  expr e;
  bound

(* Every expression in [e], [e] included, in written order. *)
let rec iter f (e : T.Expr.t) =
  f e;
  List.iter
    (function
      | Traverse.Same e -> iter f e
      | Traverse.Arm b | Traverse.Handler b | Traverse.Block b | Traverse.Lambda b ->
          List.iter (fun s -> List.iter (iter f) (Traverse.stat_exprs s)) b.T.Block.stats)
    (Traverse.parts e)

(* Every argument, and the callee of a call through a function value, can be
   had at compile time. This compiler reads that rule as requiring that the marked
   expression names no local of the verb it is in: what it is given is
   built from literals, package constants, foreign variables, the
   program's console and runtime, and other calls, marked or not, on
   those (docs/spec-divergences.md). A foreign variable declared in the
   verb is a local fixed where it is declared, which lowering declares
   again inside the call (Cgt.Lower_comptime). A local of its own, a
   lambda's parameter or a handler's binder, is its own. *)
let closed env (e : T.Expr.t) =
  let bound = bound_inside e in
  let reported = Hashtbl.create 4 in
  iter
    (fun x ->
      match x.T.Expr.node with
      | T.Expr.Var (T.Name_ref.Local l)
        when (not (Hashtbl.mem bound l.T.Local.id))
             && (not (Hashtbl.mem env.foreign_locals l.T.Local.id))
             && not (Hashtbl.mem reported l.T.Local.id) ->
          Hashtbl.replace reported l.T.Local.id ();
          error env x.T.Expr.span
            (Printf.sprintf
               "a `comptime` call is evaluated at compile time, and %s is a local of the verb it is in; \
                give the call only literals, package constants, capabilities and calls on those"
               (quote l.T.Local.name))
      | _ -> ())
    e

(* Whether a value of [t] reaches a capability: is one, or holds an `&` to
   one through the fields or elements it owns at any depth. *)
let reaches_capability env (t : Ty.t) =
  let seen = Hashtbl.create 8 in
  let rec walk (t : Ty.t) =
    Type_decls.is_capability env t
    ||
    match t with
    | Ty.Reference t | Ty.Roaming t -> walk t
    | Ty.Intrinsic { args; _ } -> List.exists (function Ty.Type t -> walk t | Ty.Number _ -> false) args
    | Ty.Named (tid, args) when not (Hashtbl.mem seen t) -> (
        Hashtbl.add seen t ();
        match Type_decls.type_info_of_id env tid with
        | Some ({ definition = Some (Struct fs | Variant fs); _ } as info) ->
            List.exists (fun (_, ft) -> walk (Ty.instantiate info.params args ft)) fs
        | Some ({ definition = Some (Distinct u); _ } as info) ->
            walk (Ty.instantiate info.params args u)
        | _ -> false)
    | _ -> false
  in
  walk t

(* A read of capability-backed state is made only inside the marked call:
   one made while its arguments are computed is a compile-time error
   (effects.md §5.6). A read takes a capability, so no call in an argument
   may be given a value that reaches one. A capability given to the marked
   call itself, or to another marked call, is read inside that call. A
   lambda given to the marked call runs inside it; a lambda anywhere else in
   the arguments may run while they are computed, so its body is held to
   the same rule. *)
let no_reads env (e : T.Expr.t) =
  let given (x : T.Expr.t) =
    match x.T.Expr.node with
    | T.Expr.Call { args; _ } | T.Expr.Call_value { args; _ } | T.Expr.Construct { args; _ } ->
        List.filter_map (function T.Arg.Value v -> Some v | T.Arg.Block _ -> None) args
    | T.Expr.Construct_fields { fields; _ } ->
        List.map (fun (f : T.Field_value.t) -> f.T.Field_value.value) fields
    | T.Expr.Op { left; right; _ } -> [ left; right ]
    | T.Expr.Flip { value; _ } -> [ value ]
    | T.Expr.Subscript { target; args; _ } -> target :: args
    | _ -> []
  in
  let rec argument (x : T.Expr.t) =
    match x.T.Expr.node with
    | T.Expr.Comptime _ -> ()
    | _ ->
        let reaching (v : T.Expr.t) = reaches_capability env v.T.Expr.ty in
        (match List.find_opt reaching (given x) with
        | Some v ->
            error env v.T.Expr.span
              (Printf.sprintf
                 "a `comptime` call's arguments pass %s, which reaches a capability, to a call that is \
                  not marked; capability-backed state is read only inside a marked call, so mark this \
                  call `comptime` too or pass the capability to the marked call itself"
                 (quote (Ty.to_string v.T.Expr.ty)))
        | None -> ());
        List.iter
          (function
            | Traverse.Same e -> argument e
            | Traverse.Arm b | Traverse.Handler b | Traverse.Block b | Traverse.Lambda b ->
                List.iter (fun s -> List.iter argument (Traverse.stat_exprs s)) b.T.Block.stats)
          (Traverse.parts x)
  in
  List.iter
    (fun (v : T.Expr.t) -> match v.T.Expr.node with T.Expr.Lambda _ -> () | _ -> argument v)
    (given e)

(* The marked expression, handlers included, is one constant (effects.md
   §5.6), so nothing in it leaves the verb it is in: no `abort`, and no
   `return` but an arm's, which gives the arm's value (adt.md §5.1). A
   handler finishes with `resolve`. A lambda's body is its own. *)
let stays env (e : T.Expr.t) =
  let rec expr ~arm (x : T.Expr.t) =
    List.iter
      (function
        | Traverse.Same x -> expr ~arm x
        | Traverse.Arm b -> block ~arm:true b
        | Traverse.Handler b | Traverse.Block b -> block ~arm b
        | Traverse.Lambda _ -> ())
      (Traverse.parts x)
  and block ~arm (b : T.Block.t) =
    List.iter
      (fun (s : T.Stat.t) ->
        (match s.T.Stat.node with
        | T.Stat.Abort _ ->
            error env s.T.Stat.span
              "a `comptime` call is evaluated whole at compile time, so nothing in it may abort the verb it \
               is in; finish its handler with `resolve`"
        | T.Stat.Return _ when not arm ->
            error env s.T.Stat.span
              "a `comptime` call is evaluated whole at compile time, so nothing in it may return from the \
               verb it is in; finish its handler with `resolve`"
        | _ -> ());
        List.iter (expr ~arm) (Traverse.stat_exprs s))
      b.T.Block.stats
  in
  expr ~arm:false e
