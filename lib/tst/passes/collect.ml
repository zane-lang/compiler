(* Passes 1 and 2 (docs/design/semantics.md §3): file every declaration of every
   package under its name, then build each file's import map.

   Nothing here reads a type. Whether two functions of one name form a legal
   overload set needs their parameter types, so that part of the collision
   rule waits for pass 4 ([check_import_overloads]). *)

open Env
module N = Sst.Nodes

let name_of (n : N.Name.t) = n.N.Name.text

(* ---------------------------------------------------------------------- *)
(* Pass 1                                                                 *)
(* ---------------------------------------------------------------------- *)

let declaration env pkg file (d : N.Decl.t) =
  let make kind =
    incr env.next_decl;
    let decl = { id = !(env.next_decl); package = pkg.name; file; span = d.N.Decl.span; kind } in
    Hashtbl.replace env.decls decl.id decl;
    pkg.decls <- decl :: pkg.decls;
    Some decl
  in
  match d.N.Decl.node with
  | N.Decl.Package _ | N.Decl.Import _ -> None
  | N.Decl.Var { name; type_; value } -> make (Constant { name; type_; value })
  | N.Decl.Type { name; params; value } ->
      make (Type_decl { name; params; value; alias = false })
  | N.Decl.Alias { name; params; value } ->
      make (Type_decl { name; params; value; alias = true })
  | N.Decl.EnumMap { enum; property; type_; entries } ->
      make (Enum_map { enum; property; type_; entries })
  | N.Decl.Verb v -> make (Verb v)

(* A name that is not a verb names one thing: two types, two constants, or a
   constant and a function of the same name leave a plain name meaning two
   things with no call site to choose between them. Functions overload, and
   whether two of them may is pass 4's question. *)
let file_under_names env pkg (decl : decl) =
  let report_twice (first : decl) at what =
    error env at
      (Printf.sprintf "%s %s is already declared at %s" what
         (quote (decl_name decl)) (where first.span))
  in
  match decl.kind with
  | Type_decl { name; alias; _ } -> (
      match Hashtbl.find_opt pkg.types (name_of name) with
      | Some first ->
          report_twice first name.N.Name.span (if alias then "the alias" else "the type")
      | None -> Hashtbl.replace pkg.types (name_of name) decl)
  | Constant { name; _ } -> (
      match Hashtbl.find_opt pkg.values (name_of name) with
      | Some (first :: _) -> report_twice first name.N.Name.span "the name"
      | _ -> Hashtbl.replace pkg.values (name_of name) [ decl ])
  | Verb { N.Verb_decl.node = N.Verb_decl.Func { name; _ }; _ } -> (
      let existing =
        Option.value ~default:[] (Hashtbl.find_opt pkg.values (name_of name))
      in
      match List.find_opt (fun d -> not (is_function d)) existing with
      | Some constant -> report_twice constant name.N.Name.span "the name"
      | None -> Hashtbl.replace pkg.values (name_of name) (existing @ [ decl ]))
  | Verb { N.Verb_decl.node = N.Verb_decl.Meth { name; _ }; _ } ->
      Hashtbl.replace pkg.method_names (name_of name) ()
  | Verb _ | Enum_map _ -> ()

let new_file ~package path =
  { path; package; qualifiers = Hashtbl.create 4; bare = Hashtbl.create 16 }

(* ---------------------------------------------------------------------- *)
(* Pass 2                                                                 *)
(* ---------------------------------------------------------------------- *)

(* How a file has already spelled a package, so a second spelling of the same
   entity is caught at the import that adds it (packages.md §3.4). *)
type form = Whole of string | All_members | One_member of string

let form_to_string pkg = function
  | Whole spelling -> "import " ^ spelling
  | All_members -> "import " ^ pkg ^ "$"
  | One_member m -> "import " ^ pkg ^ "$" ^ m

let conflicts a b =
  match (a, b) with
  | Whole _, _ | _, Whole _ -> true
  | All_members, _ | _, All_members -> true
  | One_member x, One_member y -> String.equal x y

let members_of env pkg name = package_types env pkg name @ package_values env pkg name

let import_file env (file : file) (decls : N.Decl.t list) =
  let forms : (string, form * Span.t) Hashtbl.t = Hashtbl.create 8 in
  (* The one spelling rule: each new form of a package checked against the
     forms already written for it. *)
  let record pkg form at =
    match
      List.find_opt (fun (f, _) -> conflicts f form) (Hashtbl.find_all forms pkg)
    with
    | Some (earlier, earlier_at) ->
        error env at
          (Printf.sprintf
             "%s gives the members of %s a second spelling, after `%s` at %s; a \
              member has one spelling per file"
             (quote (form_to_string pkg form))
             (quote pkg)
             (form_to_string pkg earlier)
             (where earlier_at));
        false
    | None ->
        Hashtbl.add forms pkg (form, at);
        true
  in
  (* The package an import's key names, reported where it names none. *)
  let imported (name : N.Name.t) =
    match resolve_key env file (name_of name) with
    | Found id -> Some id
    | Own ->
        error env name.N.Name.span
          (Printf.sprintf
             "%s is this file's own package; its members are available without an \
              import"
             (quote (name_of name)));
        None
    | (Unknown | Ambiguous _) as key ->
        Option.iter (error env name.N.Name.span) (key_message (name_of name) key);
        None
  in
  let bring pkg (member : N.Import_member.t) (spelling : N.Import_member.t) at =
    let found = members_of env pkg member.N.Import_member.name in
    if found = [] then
      if Hashtbl.mem (package env pkg).method_names member.N.Import_member.name then
        error env member.N.Import_member.span
          (Printf.sprintf
             "%s is a method, and a method is not importable: it is reached by \
              its subject, as `subject:%s$%s()`"
             (quote member.N.Import_member.name)
             pkg member.N.Import_member.name)
      else
        error env member.N.Import_member.span
          (Printf.sprintf "the package %s has no member %s" (quote pkg)
             (quote member.N.Import_member.name))
    else if is_private member.N.Import_member.name then
      error env member.N.Import_member.span
        (Printf.sprintf "%s is private to the package %s"
           (quote member.N.Import_member.name)
           (quote pkg))
    else if member.N.Import_member.is_type <> spelling.N.Import_member.is_type then
      error env spelling.N.Import_member.span
        (Printf.sprintf
           "an alias keeps the initial case of the name it renames, so %s cannot \
            be spelled %s"
           (quote member.N.Import_member.name)
           (quote spelling.N.Import_member.name))
    else if record pkg (One_member member.N.Import_member.name) at then
      Hashtbl.add file.bare spelling.N.Import_member.name
        { from = pkg; member = member.N.Import_member.name; at }
  in
  List.iter
    (fun (d : N.Decl.t) ->
      match d.N.Decl.node with
      | N.Decl.Import { N.Import.node; span } -> (
          match node with
          | N.Import.Package { package = p; alias } -> (
              match imported p with
              | None -> ()
              | Some id ->
                let spelling = Option.value ~default:p alias in
                if Env.is_upper (name_of spelling) then
                  error env spelling.N.Name.span
                    (Printf.sprintf
                       "an alias keeps the initial case of the name it renames, so \
                        the package %s cannot be spelled %s"
                       (quote (name_of p))
                       (quote (name_of spelling)))
                else
                  match Hashtbl.find_opt file.qualifiers (name_of spelling) with
                  | Some (other, at) ->
                      error env spelling.N.Name.span
                        (Printf.sprintf "%s already names the package %s, at %s"
                           (quote (name_of spelling))
                           (quote other) (where at))
                  | None ->
                      if record id (Whole (name_of spelling)) span then
                        Hashtbl.replace file.qualifiers (name_of spelling)
                          (id, span))
          | N.Import.Member { package = p; member; alias } ->
              Option.iter
                (fun id -> bring id member (Option.value ~default:member alias) span)
                (imported p)
          | N.Import.Members { package = p; members } ->
              Option.iter (fun id -> List.iter (fun m -> bring id m m span) members) (imported p)
          | N.Import.All { package = p } -> (
              match imported p with
              | Some id when record id All_members span ->
                let target = package env id in
                let names =
                  Hashtbl.fold (fun n _ acc -> n :: acc) target.types []
                  @ Hashtbl.fold (fun n _ acc -> n :: acc) target.values []
                  |> List.filter (fun n -> not (is_private n))
                  |> List.sort_uniq String.compare
                in
                List.iter
                  (fun n -> Hashtbl.add file.bare n { from = id; member = n; at = span })
                  names
              | _ -> ()))
      | _ -> ())
    decls

(* A bare name two imports bring, or an import and the file's own package,
   is legal only as an overload set of functions (packages.md §3.8). Anything
   else is reported at the import that brought the second meaning; an import
   never shadows. The function-against-function case needs signatures, and is
   [check_import_overloads]. *)
let check_import_collisions env (file : file) =
  let names = Hashtbl.fold (fun n _ acc -> n :: acc) file.bare [] |> List.sort_uniq String.compare in
  List.iter
    (fun name ->
      let imports = List.rev (Hashtbl.find_all file.bare name) in
      let own = members_of env file.package name in
      let seen = ref (List.map (fun d -> (d, None)) own) in
      List.iter
        (fun b ->
          let brought =
            members_of env b.from b.member |> List.filter (accessible ~from:file.package)
          in
          List.iter
            (fun (d : decl) ->
              let clashes =
                List.filter
                  (fun ((e : decl), _) ->
                    e.id <> d.id && not (is_function d && is_function e))
                  !seen
              in
              (match clashes with
              | (other, other_at) :: _ ->
                  let where_other =
                    match other_at with
                    | None -> "is declared in this package, at " ^ where other.span
                    | Some at -> "is already imported at " ^ where at
                  in
                  error env b.at
                    (Printf.sprintf
                       "this import brings %s from %s, but %s %s; an import never \
                        shadows"
                       (quote name) (quote b.from) (quote name) where_other)
              | [] -> ());
              seen := !seen @ [ (d, Some b.at) ])
            brought)
        imports)
    names

(* The half of §3.8 that waits for signatures: functions of one bare name,
   from different packages, must differ in their parameter types. *)
let check_import_overloads env (file : file) =
  let names = Hashtbl.fold (fun n _ acc -> n :: acc) file.bare [] |> List.sort_uniq String.compare in
  List.iter
    (fun name ->
      let own =
        members_of env file.package name |> List.filter is_function
        |> List.map (fun d -> (d, None))
      in
      let seen = ref own in
      List.iter
        (fun b ->
          members_of env b.from b.member
          |> List.filter (fun d -> is_function d && accessible ~from:file.package d)
          |> List.iter (fun (d : decl) ->
                 let key d =
                   Option.map
                     (fun (s : Signature.t) ->
                       Ty.canonical
                         (List.map
                            (fun (p : Signature.param) -> Ty.without_mut (Ty.strip_mode p.ty))
                            s.params))
                     (Hashtbl.find_opt env.signatures d.id)
                 in
                 (match
                    List.find_opt
                      (fun ((e : decl), _) ->
                        e.id <> d.id && e.package <> d.package
                        && key e <> None && key e = key d)
                      !seen
                  with
                 | Some (other, _) ->
                     error env b.at
                       (Printf.sprintf
                          "this import brings %s from %s, which takes the same \
                           parameter types as the %s declared at %s; the two cannot \
                           be told apart at a call"
                          (quote name) (quote b.from) (quote name) (where other.span))
                 | None -> ());
                 if not (List.exists (fun ((e : decl), _) -> e.id = d.id) !seen) then
                   seen := !seen @ [ (d, Some b.at) ]))
        (List.rev (Hashtbl.find_all file.bare name)))
    names

(* ---------------------------------------------------------------------- *)
(* Both passes                                                            *)
(* ---------------------------------------------------------------------- *)

(* The package dependency graph is acyclic (dependencies.md §10). Each import
   that closes a cycle is reported there, with the packages around the cycle
   in order. *)
let check_import_cycles env (loaded : (package * (file * Assembly.file) list) list) =
  let edges : (string, string * Span.t) Hashtbl.t = Hashtbl.create 16 in
  List.iter
    (fun ((pkg : package), files) ->
      List.iter
        (fun ((file : file), (f : Assembly.file)) ->
          List.iter
            (fun (d : N.Decl.t) ->
              match d.N.Decl.node with
              | N.Decl.Import { N.Import.node; span } -> (
                  let key =
                    match node with
                    | N.Import.Package { package = p; _ }
                    | N.Import.Member { package = p; _ }
                    | N.Import.Members { package = p; _ }
                    | N.Import.All { package = p } ->
                        name_of p
                  in
                  match resolve_key env file key with
                  | Found target -> Hashtbl.add edges pkg.name (target, span)
                  | Own | Unknown | Ambiguous _ -> ())
              | _ -> ())
            f.sst.N.Package.decls)
        files)
    loaded;
  let finished = Hashtbl.create 16 in
  let rec visit path name =
    if not (Hashtbl.mem finished name) then begin
      List.iter
        (fun (target, span) ->
          if List.mem target path then begin
            let rec from = function
              | p :: rest -> if String.equal p target then p :: rest else from rest
              | [] -> []
            in
            let cycle = from (List.rev (name :: path)) @ [ target ] in
            error env span
              (Printf.sprintf
                 "this import closes a cycle of packages, %s; the packages of a \
                  build import one another without a cycle (dependencies.md §10)"
                 (String.concat " -> " (List.map quote cycle)))
          end
          else visit (name :: path) target)
        (List.rev (Hashtbl.find_all edges name));
      Hashtbl.replace finished name ()
    end
  in
  List.iter (visit []) !(env.package_order)

let run env (assembled : Assembly.package list) =
  (* Every package is registered before any import is read, so an import may
     name a package given later on the command line. *)
  let loaded =
    List.map
      (fun (p : Assembly.package) ->
        let files =
          List.map (fun (f : Assembly.file) -> (new_file ~package:p.id f.path, f)) p.files
        in
        let pkg =
          {
            name = p.id;
            declared = p.name;
            imports = p.imports;
            is_root = p.is_root;
            files = List.map fst files;
            decls = [];
            types = Hashtbl.create 16;
            values = Hashtbl.create 16;
            method_names = Hashtbl.create 16;
          }
        in
        Hashtbl.replace env.packages p.id pkg;
        env.package_order := !(env.package_order) @ [ p.id ];
        (pkg, files))
      assembled
  in
  List.iter
    (fun (pkg, files) ->
      List.iter
        (fun (file, (f : Assembly.file)) ->
          List.iter
            (fun d -> ignore (declaration env pkg file d))
            f.sst.N.Package.decls)
        files;
      pkg.decls <- List.rev pkg.decls;
      List.iter (file_under_names env pkg) pkg.decls)
    loaded;
  List.iter
    (fun (_, files) ->
      List.iter
        (fun (file, (f : Assembly.file)) ->
          import_file env file f.sst.N.Package.decls;
          check_import_collisions env file)
        files)
    loaded;
  check_import_cycles env loaded
