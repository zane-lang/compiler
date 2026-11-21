(* The arguments the checker supplies to a call, which a program never
   writes: the conversion lambdas a worker's `test`, a pool's `start` and
   `ArrayRef.fill`'s `index` take, and a stateful pool's publish function
   (concurrency.md §6, generics.md §8.4). [Check] resolves each such call
   against the signature without these parameters, then adds them here. *)

open Env
module T = Nodes
module S = Signature
open Context
open Instances
open Overloads

(* A lambda from [src] to [dst] that returns its parameter, converted by the
   one implicit constructor between them when [src] is not already a [dst]:
   a conversion a call cannot write itself, since it is of a function
   value's parameter or result rather than of a value. *)
let conversion_lambda env span ~name ~src ~dst ~missing =
  let local = fresh_local env name src span in
  let read = mk (T.Expr.Var (T.Name_ref.Local local)) src span in
  let converted =
    if Ty.assignable ~dst ~src || src = Ty.Error || dst = Ty.Error then read
    else
      match implicit_constructors env ~src ~dst with
      | [ ((s, subst) as found) ] ->
          request env s subst span;
          coerce_value read found
      | [] ->
          error env span (missing ());
          read
      | several ->
          error env span
            (Printf.sprintf "more than one implicit constructor converts %s to %s: %s"
               (quote (Ty.to_string src)) (quote (Ty.to_string dst))
               (String.concat ", " (List.map (fun ((s : S.t), _) -> quote (S.to_string s)) several)));
          read
  in
  let body = { T.Block.stats = [ { T.Stat.node = T.Stat.Return converted; span } ]; span } in
  let v = { Ty.this_ = None; params = [ src ]; ret = dst; abort = None; is_mut = false } in
  mk (T.Expr.Lambda { params = [ local ]; body }) (Ty.Verb v) span

(* The `test` of a worker call: `@primitives$Bool(result R) { return result; }`,
   whose return converts its value by the single implicit constructor from
   `R`. *)
let worker_test env span result =
  conversion_lambda env span ~name:"result" ~src:result ~dst:(Intrinsics.prim "Bool") ~missing:(fun () ->
      Printf.sprintf
        "a worker's step returns %s, and it must convert to %s, as a condition does, with no \
         implicit constructor between them (control-flow.md §4.1)"
        (quote (Ty.to_string result)) (quote (Ty.to_string (Intrinsics.prim "Bool"))))

(* A pool's `start` without the parameters the checker supplies, which is
   what a call resolves against. *)
let pool_view (s : S.t) =
  match Intrinsics.pool_start_hidden s with
  | Some n -> { s with S.params = List.filteri (fun i _ -> i < List.length s.S.params - n) s.S.params }
  | None -> s

(* The publish function value a stateful pool's step is given (§6.5):
   `P(event E) { return @primitives$publish(event); }`, its return
   converting the `@primitives$Unit` to `P` by the one implicit constructor
   between them. *)
let pool_publish env span e p =
  let local = fresh_local env "event" e span in
  let read = mk (T.Expr.Var (T.Name_ref.Local local)) e span in
  let unit = Intrinsics.prim "Unit" in
  let f = Intrinsics.publish_function in
  let callee = verb_ref f (List.map (fun (q : Ty.param) -> (q.Ty.id, Ty.Type e)) f.S.generics) in
  let call = mk (T.Expr.Call { callee; args = [ T.Arg.Value read ]; handler = None }) unit span in
  let converted =
    if Ty.assignable ~dst:p ~src:unit || p = Ty.Error then call
    else
      match implicit_constructors env ~src:unit ~dst:p with
      | [ ((s, subst) as found) ] ->
          request env s subst span;
          coerce_value call found
      | [] ->
          error env span
            (Printf.sprintf
               "a pool's step takes a publish function returning %s, and a publish returns %s, with no \
                implicit constructor between them (concurrency.md §6.2)"
               (quote (Ty.to_string p)) (quote (Ty.to_string unit)));
          call
      | several ->
          error env span
            (Printf.sprintf "more than one implicit constructor converts %s to %s: %s" (quote (Ty.to_string unit))
               (quote (Ty.to_string p))
               (String.concat ", " (List.map (fun ((s : S.t), _) -> quote (S.to_string s)) several)));
          call
  in
  let body = { T.Block.stats = [ { T.Stat.node = T.Stat.Return converted; span } ]; span } in
  let v = { Ty.this_ = None; params = [ e ]; ret = p; abort = None; is_mut = false } in
  mk (T.Expr.Lambda { params = [ local ]; body }) (Ty.Verb v) span

(* A call to a pool's method, resolved (concurrency.md §6.2, §6.6). `start`
   gets its whole signature back and the arguments the checker supplies:
   `test`, the step result's conversion to `@primitives$Bool`, as a
   worker's call gets it, and for a pool with state the publish function
   value (pool_publish). `elements` copies each element, so it reads a pool
   of value-typed elements only. *)
let pool_method env span (o : outcome) =
  match (Intrinsics.pool_start_hidden o.sig_, o.sig_.S.owner) with
  | Some _, owner -> (
      let full = List.find_map (fun (_, (s : S.t)) -> if s.S.owner = owner then Some s else None) Intrinsics.pool_methods in
      let full = Option.get full in
      let step = List.nth o.sig_.S.params (List.length o.sig_.S.params - 1) in
      match Ty.subst o.subst step.S.ty with
      | Ty.Verb v ->
          let test = worker_test env span v.Ty.ret in
          let publish =
            match v.Ty.params with
            | [ _; Ty.Verb { Ty.params = [ e ]; ret; _ } ] -> [ Some (T.Arg.Value (pool_publish env span e ret)) ]
            | _ -> []
          in
          { o with sig_ = full; converted = o.converted @ (Some (T.Arg.Value test) :: publish) }
      | _ -> { o with sig_ = full })
  | None, S.Intrinsic "@primitives$elements" ->
      (match Ty.subst o.subst (List.hd o.sig_.S.params).S.ty with
      | Ty.Intrinsic { args = Ty.Type t :: _; _ } when Type_decls.is_reference env t ->
          error env span
            (Printf.sprintf
               "`elements` copies each element, and %s is a reference type, which its pool alone owns \
                and which is never copied (concurrency.md §6.6)"
               (quote (Ty.to_string t)))
      | _ -> ());
      o
  | None, _ -> o

(* The `index` of `ArrayRef.fill`: `I(position @primitives$I64) { return
   position; }`, its return converting by the one implicit constructor to
   `I`, the type `make` takes its position as (generics.md §8.4). *)
let fill_index env span index =
  let src = Intrinsics.prim "I64" in
  conversion_lambda env span ~name:"position" ~src ~dst:index ~missing:(fun () ->
      Printf.sprintf
        "`ArrayRef.fill`'s `make` takes its position as %s, and a position is %s, with no \
         implicit constructor between them (generics.md §8.4)"
        (quote (Ty.to_string index)) (quote (Ty.to_string src)))
