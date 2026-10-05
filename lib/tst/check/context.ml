(* Pass 5's context (docs/design/semantics.md §3): what [Check] carries
   through a body -- its scopes, locals, return and resolve targets -- and the
   type questions it asks of a declaration's definition. Split from check.ml
   because none of it is part of the recursive walk. *)

open Env
module T = Nodes
module S = Signature

type role = Symbol | Parameter | This | Binder

type binding = { local : T.Local.t; role : role }

(* Where a `return` and an `abort` go. An arm of a `match` is its own target:
   `=> expr` is `{ return expr }` (adt.md §5.1), so a `return` in an arm is
   the arm's value, and an arm that aborts makes the whole `match` abortable
   (§5.4). *)
type arm_results = {
  mutable results : (Ty.t * Span.t) list;
  mutable aborts : (Ty.t * Span.t) list;
}

type ret_target =
  | To_verb of { ret : Ty.t; abort : Ty.t option }
  | To_arm of arm_results
  | No_return

(* Where a `resolve` goes: the handler it finishes. *)
type resolve_target = To_handler of Ty.t | No_resolve

type ctx = {
  file : Env.file;
  package : string;
  is_root : bool;
  (* Parameters in scope and what they stand for; in an instance, the
     arguments it was instantiated at. *)
  params : (string * Ty.arg) list;
  mutable scopes : (string, binding) Hashtbl.t list;
  ret_target : ret_target;
  resolve_target : resolve_target;
  (* The subject type of the method being checked, which is what grants
     access to `_` fields (types.md §2.3). *)
  this_type : Ty.t option;
  is_mut : bool;
  (* In a constructor: what `init{ }` builds. *)
  building : Ty.t option;
}


let type_scope ctx = Type_decls.scope ~params:ctx.params ctx.file

let find_local ctx name = List.find_map (fun tbl -> Hashtbl.find_opt tbl name) ctx.scopes

let push ctx = { ctx with scopes = Hashtbl.create 8 :: ctx.scopes }

let fresh_local env name ty span =
  incr env.next_local;
  { T.Local.id = !(env.next_local); name; ty; span }

let bind ctx role (local : T.Local.t) =
  match ctx.scopes with
  | top :: _ -> Hashtbl.replace top local.T.Local.name { local; role }
  | [] -> ()

(* D14: a local may not shadow a name already in scope -- an enclosing local
   or parameter, a parameter of the generic signature, or a package-scope name
   the file can write. *)
let declare env ctx role (name : N.Name.t) ty =
  let text = name.N.Name.text and span = name.N.Name.span in
  (match find_local ctx text with
  | Some b ->
      error env span
        (Printf.sprintf
           "%s is already declared at %s, and a local may not shadow a name in scope"
           (quote text) (where b.local.T.Local.span))
  | None -> (
      if List.mem_assoc text ctx.params then
        error env span
          (Printf.sprintf "%s is a parameter of this verb, and a local may not shadow it"
             (quote text))
      else
        match lookup_values env ctx.file text with
        | d :: _ ->
            error env span
              (Printf.sprintf
                 "%s names the declaration at %s, and a local may not shadow a name in \
                  scope"
                 (quote text) (where d.span))
        | [] -> ()));
  let local = fresh_local env text ty span in
  bind ctx role local;
  local

let mk node ty span = { T.Expr.node; ty; span }
let invalid span = mk T.Expr.Invalid Ty.Error span

(* A declared type's definition with its arguments applied. A distinct type
   reads through to the type it was defined as, since it is "structurally
   equal to its right-hand side" (types.md §5.1). *)
let rec definition env ?(depth = 0) (t : Ty.t) : (Ty.type_id * definition) option =
  match Ty.strip_guest t with
  | Ty.Named (tid, args) -> (
      match Type_decls.type_info_of_id env tid with
      | Some ({ definition = Some def; _ } as info) -> (
          let s = Ty.bindings info.params args in
          let apply = List.map (fun (n, t) -> (n, Ty.subst s t)) in
          match def with
          | Struct fs -> Some (tid, Struct (apply fs))
          | Variant cs -> Some (tid, Variant (apply cs))
          | Enum ms -> Some (tid, Enum ms)
          | Distinct rhs -> if depth > 16 then None else definition env ~depth:(depth + 1) (Ty.subst s rhs))
      | _ -> None)
  | _ -> None

let accessible_sig ctx (s : S.t) =
  match s.home with
  | S.Package p -> String.equal p ctx.package || not (is_private s.name)
  | S.Namespace _ -> true
