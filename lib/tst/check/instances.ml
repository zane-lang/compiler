(* Generic instances (D12): the instances pass 5 records as calls resolve to
   generic verbs, how many of one declaration make recursion, and the rule
   that a concept type is never storage. *)

open Env
module T = Nodes
module S = Signature

open Context


(* How many instances of one declaration are enough to call it recursion
   without end: `f<T>` calling `f<Pair<T>>`, which no program can finish
   instantiating. *)
let instance_limit = 64

let binding_args (s : S.t) (subst : Ty.subst) =
  List.map
    (fun (p : Ty.param) ->
      ( p,
        match List.assoc_opt p.id subst with
        | Some a -> a
        | None -> Type_decls.param_arg p ))
    s.generics

let describe_instance (s : S.t) subst at =
  Printf.sprintf "in %s with %s, required at %s" (quote s.name)
    (String.concat ", "
       (List.map (fun ((p : Ty.param), a) -> p.name ^ " = " ^ Ty.arg_to_string a) (binding_args s subst)))
    (where at)

let verb_ref (s : S.t) subst =
  { T.Verb_ref.owner = s.owner; name = s.name; instance = binding_args s subst }


(* A concept type is never storage (syntax.md §2.8), and a generic call can
   make it one no written type shows: `Jar(body)` builds a `Jar` whose field
   holds the block, which never escapes the call it is written at
   (control-flow.md §2.2). A call whose result is itself a concept, as
   `echo(body)` is, stores nothing; where that value goes is checked there. *)
let check_result env (s : S.t) subst at =
  let ret = Ty.subst subst s.ret in
  match (ret, Type_decls.concept_in ret) with
  | Ty.Concept _, _ | _, None -> true
  | _, Some c ->
      error env at
        (Printf.sprintf "this call builds %s, which holds %s; a concept type is never storage"
           (quote (Ty.to_string ret)) (quote (Ty.to_string c)));
      false

(* generics.md §3.6: an instance that puts a reference type where a value
   mould holds only values, or a value type under an `&`, is reported at the type's origin, the argument it
   was read from: a type passed as a value, or the value an inferred one was
   inferred from. A generic verb that only forwards its parameter is never
   the origin, so the instance is not made, and nothing inside it reports
   the same mistake again. *)
let check_kinds env (s : S.t) subst at (args : T.Arg.t option list) =
  let instantiated = List.map (fun (p : S.param) -> (p, Ty.subst subst p.S.ty)) s.params in
  (* A subscript's result is a place, and a constructor's is the value it
     builds: neither hands back a borrow. *)
  let returns = match s.kind with S.Subscript | S.Constructor _ -> false | _ -> true in
  let found =
    List.find_map
      (fun (slot, top, raw, t) ->
        match Type_decls.filled_references env raw t with
        | bad :: _ -> Some { Type_decls.path = [ slot ]; bad; slot = Type_decls.Under_reference }
        | [] -> (
            match Type_decls.bare_results env ~top raw t with
            | bad :: _ -> Some { Type_decls.path = [ slot ]; bad; slot = Type_decls.Bare_result }
            | [] -> Type_decls.wrong_kind env (Ty.strip_mode t)))
      (((Printf.sprintf "the result of %s" (quote s.name), returns, s.ret, Ty.subst subst s.ret)
       :: Option.fold ~none:[]
            ~some:(fun a -> [ (Printf.sprintf "the abort type of %s" (quote s.name), true, a, Ty.subst subst a) ])
            s.abort)
      @ List.map
          (fun ((p : S.param), t) ->
            (Printf.sprintf "the parameter %s" (quote p.S.name), false, p.S.ty, t))
          instantiated)
  in
  match found with
  | None -> true
  | Some ({ Type_decls.bad; _ } as f) ->
      let reads (p : S.param) =
        List.exists
          (fun (q : Ty.param) ->
            match List.assoc_opt q.id subst with
            | Some (Ty.Type x) ->
                Ty.equal (Ty.strip_mode x) (Ty.strip_mode bad)
                && (p.S.binds = Some q || List.exists (fun r -> r.Ty.id = q.id) (Ty.free_params p.S.ty))
            | _ -> false)
          s.generics
      in
      let origin =
        List.find_map
          (fun ((p : S.param), a) ->
            match a with
            | Some (T.Arg.Value e) when reads p -> Some e.T.Expr.span
            | _ -> None)
          (List.combine s.params (if List.length args = List.length s.params then args else List.map (fun _ -> None) s.params))
      in
      error env (Option.value ~default:at origin) (Type_decls.describe_wrong_kind f);
      false

(* A call that builds storage out of a concept was reported, and its instance
   would only report it again. *)
let request env ?(args = []) (s : S.t) subst at =
  match s.owner with
  | _ when not (check_result env s subst at) -> ()
  | _ when s.generics <> [] && not (check_kinds env s subst at args) -> ()
  | _ when !(env.defining) -> ()
  | S.Declared id when s.generics <> [] ->
      let args = binding_args s subst in
      if List.exists (fun (_, a) -> Ty.arg_contains_error a) args then ()
      else
        let key =
          string_of_int id ^ ":"
          ^ String.concat "," (List.map (fun (_, a) -> Ty.arg_to_string a) args)
        in
        if not (Hashtbl.mem env.instance_keys key) then begin
          Hashtbl.add env.instance_keys key ();
          let count = 1 + Option.value ~default:0 (Hashtbl.find_opt env.instance_counts id) in
          Hashtbl.replace env.instance_counts id count;
          if count > instance_limit then begin
            if count = instance_limit + 1 then
              error env at
                (Printf.sprintf
                   "%s is instantiated at more than %d sets of arguments; its calls to \
                    itself never reach a fixed set"
                   (quote s.name) instance_limit)
          end
          else Queue.add { p_decl = Hashtbl.find env.decls id; p_sig = s; p_subst = subst; p_at = at } env.pending
        end
  | _ -> ()
