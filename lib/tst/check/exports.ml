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

(* The signature of the exported lambda of type [ty], whose C symbol is
   [symbol]. A host calls it as C calls a function value (ffi.md §3.6), so
   its parameters and result are those a function value passed to C may
   have, and it declares no abort type, since no Zane caller handles its
   abort. *)
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
  | Ty.Verb f when f.Ty.this_ <> None ->
      error env at
        "an exported lambda with a subject borrows a C-held object, which zanec does not support yet (packages.md §8.5)"
  | Ty.Verb f ->
      List.iter
        (fun (p : Ty.t) ->
          if not (Foreign_decls.function_param env p) then
            error env at
              (Printf.sprintf
                 "an exported lambda takes what C passes a function value, and C passes no %s: a scalar, `@primitives$Bool`, a C-compatible value type, a string, a list or array of scalars, or a data handle, borrowed or as a roaming owner `^` (packages.md §8.2, ffi.md §3.6)"
                 (quote (Ty.to_string p))))
        f.Ty.params;
      if not (Foreign_decls.function_result env f.Ty.ret) then
        error env at
          (Printf.sprintf
             "an exported lambda gives what a function value gives C, and C takes no %s: a scalar, `@primitives$Bool`, a C-compatible value type, or `@primitives$Unit` (packages.md §8.2, ffi.md §3.6)"
             (quote (Ty.to_string f.Ty.ret)))
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
