(* Exported lambdas (packages.md §8.2, §8.3): what each one's signature may
   be, and which of them a build gives C symbols.

   Entry-point rights (§8.4) are given where a body is checked
   ([Program.package_context]), and the rule that only root-package code
   names an exported lambda where a name is resolved ([Check]). *)

open Env
module N = Sst.Nodes
module T = Nodes

(* A C identifier: a letter or `_`, then letters, digits and `_`. *)
let is_c_identifier s =
  let first c = c = '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') in
  let rest c = first c || (c >= '0' && c <= '9') in
  String.length s > 0 && first s.[0] && String.for_all rest s

(* Whether a value of type [t] reaches a [target], or an `&` to one, through
   its members, cases and elements (concurrency.md §4.7): a C-held object of
   such a type is a second path to an object of [target]. *)
let reaches env ~target (t : Ty.t) =
  let seen = Hashtbl.create 8 in
  let rec walk (t : Ty.t) =
    match t with
    | Ty.Reference u | Ty.Roaming u -> walk u
    | t when Ty.equal t target -> true
    | Ty.Named (tid, args) when not (Hashtbl.mem seen t) -> (
        Hashtbl.add seen t ();
        match Type_decls.type_info_of_id env tid with
        | Some ({ definition = Some (Struct fs | Variant fs); _ } as info) ->
            List.exists (fun (_, ft) -> walk (Ty.instantiate info.params args ft)) fs
        | Some ({ definition = Some (Distinct u); _ } as info) -> walk (Ty.instantiate info.params args u)
        | _ -> false)
    | Ty.Intrinsic { args; _ } -> List.exists (function Ty.Type a -> walk a | Ty.Number _ -> false) args
    | _ -> false
  in
  walk t

(* What an exported lambda's parameter is, by its type (packages.md §8.2,
   §8.5): what C passes a function value (ffi.md §3.6), a C-held object it
   borrows, written `T`, or one it ends, written `^T`. *)
type param = Crossing | Borrowed | Ended | Refused

let param env (t : Ty.t) =
  match t with
  | Ty.Roaming _ when Foreign_decls.c_held env t -> Ended
  | Ty.Named _ when Foreign_decls.c_held env t -> Borrowed
  | _ when Foreign_decls.function_param env t -> Crossing
  | _ -> Refused

(* The signature of the exported lambda of type [ty], whose C symbol is
   [symbol]. A host calls it as C calls a function value (ffi.md §3.6), so
   its parameters and result are those a function value passed to C may
   have, or C-held objects (packages.md §8.5): a `^T` result hands C an
   owner, a `T` parameter or subject borrows one, and a `^T` parameter ends
   one. A result whose lists cross as views lives in the subject's
   top-level scope, so only a lambda whose subject is `this T mut` returns
   one. It declares no abort type, since no Zane caller handles its abort,
   and no parameter of a `mut` subject's lambda reaches an object of the
   subject's type, since C may pass the same pointer twice (concurrency.md
   §4.7). *)
let check_lambda env (ty : Ty.t) (symbol : N.Name.t) =
  let at = symbol.N.Name.span in
  if not (is_c_identifier symbol.N.Name.text) then
    error env at
      (Printf.sprintf "%s is not a C identifier, and an exported lambda becomes the C function it names (packages.md §8.2)"
         (quote symbol.N.Name.text));
  match ty with
  | Ty.Verb f when f.Ty.abort <> None ->
      error env at
        "an exported lambda declares no abort type: a host calls it, and no Zane caller handles its abort (packages.md §8.2)"
  | Ty.Verb f ->
      (match f.Ty.this_ with
      | Some t when not (Foreign_decls.c_held env t) ->
          error env at
            (Printf.sprintf
               "an exported lambda's subject is a C-held object, of a reference type that is no foreign handle, and %s is not one (packages.md §8.5)"
               (quote (Ty.to_string t)))
      | _ -> ());
      List.iter
        (fun (p : Ty.t) ->
          match param env p with
          | Refused ->
              error env at
                (Printf.sprintf
                   "an exported lambda takes what C passes a function value or a C-held object, and C passes no %s: a scalar, `@primitives$Bool`, a C-compatible value type, a string, a list or array of scalars, a data handle, borrowed or as a roaming owner `^`, or a C-held object, borrowed as `T` or ended as `^T` (packages.md §8.2, §8.5, ffi.md §3.6)"
                   (quote (Ty.to_string p)))
          | Crossing | Borrowed | Ended -> ())
        f.Ty.params;
      let mut_subject = match f.Ty.this_ with Some t when f.Ty.is_mut -> Some (Ty.strip_mode t) | _ -> None in
      let viewed = Foreign_decls.list_of f.Ty.ret <> None in
      let owner = (match f.Ty.ret with Ty.Roaming _ -> true | _ -> false) && Foreign_decls.c_held env f.Ty.ret in
      if viewed && mut_subject = None then
        error env at
          "an exported lambda returns a value whose lists cross as views only when its subject is `this T mut`, whose top-level scope the value lives in (packages.md §8.2, §8.5)"
      else if not (owner || viewed || Foreign_decls.function_result env f.Ty.ret) then
        error env at
          (Printf.sprintf
             "an exported lambda gives what a function value gives C, an owner `^T` of a new C-held object, or, with a subject `this T mut`, a list C reads as a view, and C takes no %s: a scalar, `@primitives$Bool`, a C-compatible value type, `@primitives$Unit`, `^T`, or a list (packages.md §8.2, §8.5, ffi.md §3.6)"
             (quote (Ty.to_string f.Ty.ret)));
      Option.iter
        (fun subject ->
          List.iter
            (fun (p : Ty.t) ->
              if param env p <> Refused && reaches env ~target:subject p then
                error env at
                  (Printf.sprintf
                     "an exported lambda whose subject is `this %s mut` takes no other parameter through which a %s is reachable, and %s reaches one: C may pass the same pointer twice (concurrency.md §4.7)"
                     (Ty.to_string subject) (quote (Ty.to_string subject)) (quote (Ty.to_string p))))
            f.Ty.params)
        mut_subject
  | Ty.Error -> ()
  | _ -> Diagnostic.bug ~span:at "semantics: an exported declaration is not a lambda"

(* The exported lambdas of the package [name], each with its C symbol and
   where the symbol is written. *)
let declared env name =
  List.filter_map
    (fun (d : decl) ->
      match d.kind with
      | Constant { export = Some symbol; _ } -> Some (d, symbol)
      | _ -> None)
    (package env name).decls

let root env = List.find_opt (fun name -> (package env name).is_root) (Names.package_order env.names)

(* The packages the root's export lines name. *)
let lines env = match root env with Some r -> List.map fst (package env r).export_lines | None -> []

(* Whether the package [name] declares `main`. *)
let declares_main env name =
  List.exists
    (fun (d : decl) ->
      match d.kind with Verb { N.Verb_decl.node = N.Verb_decl.Func { name = n; _ }; _ } -> n.N.Name.text = "main" | _ -> false)
    (package env name).decls

(* The exported lambdas the build gives C symbols: the root's own, then
   those of each package its export lines name (§8.3). Every C name occurs
   once in a build (§8.2). A build without a root exports none. *)
let of_build env : T.Export.t list =
  match root env with
  | None -> []
  | Some root ->
      (* A program package declares `main`, and a plugin package carries
         the export lines; a test package, always named `test`, may do both
         (§8.1, §7.2). *)
      let pkg = package env root in
      (match pkg.export_lines with
      | (_, at) :: _ when pkg.declared <> "test" && declares_main env root ->
          error env at
            (Printf.sprintf
               "%s declares `main`, so it is a program package, and a program package carries no export lines; a plugin package, which declares no `main`, or a test package does (packages.md §8.1)"
               (quote pkg.declared))
      | _ -> ());
      let exported = List.concat_map (fun name -> List.map (fun e -> (name, e)) (declared env name))
          (root :: List.map fst (package env root).export_lines)
      in
      let seen = Hashtbl.create 16 in
      List.iter
        (fun (_, ((_ : decl), (symbol : N.Name.t))) ->
          match Hashtbl.find_opt seen symbol.N.Name.text with
          | Some earlier ->
              error env symbol.N.Name.span
                (Printf.sprintf "this build already exports a C function %s, at %s; each C name occurs once in a build (packages.md §8.2)"
                   (quote symbol.N.Name.text) (where earlier))
          | None -> Hashtbl.replace seen symbol.N.Name.text symbol.N.Name.span)
        exported;
      List.map
        (fun (package, ((d : decl), (symbol : N.Name.t))) -> { T.Export.decl = d.id; package; symbol = symbol.N.Name.text })
        exported
