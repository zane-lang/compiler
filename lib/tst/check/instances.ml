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
let check_result (s : S.t) subst at =
  let ret = Ty.subst subst s.ret in
  match (ret, Type_decls.concept_in ret) with
  | Ty.Concept _, _ | _, None -> true
  | _, Some c ->
      error at
        (Printf.sprintf "this call builds %s, which holds %s; a concept type is never storage"
           (quote (Ty.to_string ret)) (quote (Ty.to_string c)));
      false

(* A call that builds storage out of a concept was reported, and its instance
   would only report it again. *)
let request (s : S.t) subst at =
  match s.owner with
  | _ when not (check_result s subst at) -> ()
  | _ when !defining -> ()
  | S.Declared id when s.generics <> [] ->
      let args = binding_args s subst in
      if List.exists (fun (_, a) -> Ty.arg_contains_error a) args then ()
      else
        let key =
          string_of_int id ^ ":"
          ^ String.concat "," (List.map (fun (_, a) -> Ty.arg_to_string a) args)
        in
        if not (Hashtbl.mem instance_keys key) then begin
          Hashtbl.add instance_keys key ();
          let count = 1 + Option.value ~default:0 (Hashtbl.find_opt instance_counts id) in
          Hashtbl.replace instance_counts id count;
          if count > instance_limit then begin
            if count = instance_limit + 1 then
              error at
                (Printf.sprintf
                   "%s is instantiated at more than %d sets of arguments; its calls to \
                    itself never reach a fixed set"
                   (quote s.name) instance_limit)
          end
          else Queue.add { p_decl = Hashtbl.find decls id; p_sig = s; p_subst = subst; p_at = at } pending
        end
  | _ -> ()
