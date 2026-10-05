(* The input to semantics: every package in the build, each one the files of
   its directory, parsed and desugared.

   Stages 1 and 2 never look past a file, so the binary could hand them one.
   Stage 3 cannot work that way. A package is "one order-independent
   compilation unit" made of every file in its directory (packages.md §2.3), a
   name in one file resolves to a declaration in another, and `Int` is a
   declaration in `core`, which is a package like any other. So this is the
   first place files are grouped: by directory, into packages. A package's name
   is the `name` its manifest gives it (§2.1), which the driver passes along;
   when it passes none, the directory's basename stands in, which is how the
   test fixtures name their packages. See docs/design/semantics.md §2.

   Where the directories come from is the driver's business. Fetching and the
   manifest (dependencies.md) are not modelled; a build is the list of
   directories it was given, and the first of them is the root (packages.md
   §6.1). A package given a stamp is one version of a published package
   (dependencies.md §6.1), and its identity is its stamped name, so two
   versions of one package, or two packages of one name, are two packages of
   the build (§11, docs/design/separate-compilation.md C10). *)

module Span = Source.Span

type file = {
  path : string;
  (* Kept for rendering a diagnostic against it later: [Diagnostic.render]
     needs the text a span points into. *)
  source : string;
  sst : Sst.Nodes.Package.t;
}

type package = {
  (* What the package is called in the build: its name, after its stamp when
     it has one. Unique within a build, and what its symbols are named by. *)
  id : string;
  (* The name its manifest gives it, which its files declare. *)
  name : string;
  dir : string;
  is_root : bool;
  files : file list;
  (* The packages its imports name, each by the key the package imports it
     by and the package's [id], when the driver says. Empty when it does
     not, and then an import names a package by its name. *)
  imports : (string * string) list;
}

(* What went wrong, with the text of the file it points into when there is
   one: a package that failed to load is no package, so its files' text
   travels with the problem for the caret to be drawn under. *)
type problem = Diagnostic.t * Source.Files.t

(* Every problem a build ran into, and the text they point into. *)
type failure = { diagnostics : Diagnostic.t list; sources : Source.Files.t }

let in_directory dir message = (Diagnostic.in_directory dir message, [])

(* What the file system said, without the path it starts with: [Sys_error]
   messages read "PATH: reason", and a problem already names its path. *)
let reason ~path message =
  let prefix = path ^ ": " in
  if String.starts_with ~prefix message then
    String.sub message (String.length prefix)
      (String.length message - String.length prefix)
  else message

let source_extension = ".zn"

(* An empty span at the start of the file, for a report about a declaration
   that was not written at all. *)
let file_start path =
  let position =
    { Lexing.pos_fname = path; pos_lnum = 1; pos_bol = 0; pos_cnum = 0 }
  in
  Span.of_loc (position, position)

(* The files that make up the package: those "directly in" its directory
   (§2.3), so a subdirectory is some other package and not part of this one.
   Sorted because the order the file system lists them in is not something a
   golden file should depend on -- and file order is "semantically irrelevant"
   anyway, so no order is more correct than another. *)
let source_files dir =
  (* An entry that cannot be examined, such as a dangling link, is kept as a
     file: reading it is what fails, and that failure is reported against its
     path like any other file's. *)
  let is_directory path = try Sys.is_directory path with Sys_error _ -> false in
  Sys.readdir dir |> Array.to_list
  |> List.filter (fun entry ->
         Filename.check_suffix entry source_extension
         && not (is_directory (Filename.concat dir entry)))
  |> List.sort String.compare
  |> List.map (Filename.concat dir)

(* Whatever succeeded, if everything did; otherwise every problem, from every
   part that failed. One pass over the results, splitting as it goes. *)
let all_or_problems results =
  match
    List.partition_map
      (function Ok value -> Either.Left value | Error problems -> Right problems)
      results
  with
  | values, [] -> Ok values
  | _, problems -> Error (List.concat problems)

let read_file path = In_channel.with_open_bin path In_channel.input_all

(* §2.2: every file "**MUST** begin with a `package packageName` declaration
   whose name exactly matches" the package's name. The grammar accepts a
   `package` line anywhere at package scope, so "begin with" and "exactly one"
   are both checked here. *)
let check_package_line ~name ~given ~path ~source (cst : Cst.Nodes.Package.t) =
  let problem span message =
    (Diagnostic.error span message, [ (path, source) ])
  in
  let package_lines =
    List.filter_map
      (fun (decl : Cst.Nodes.Decl.t) ->
        match decl.Cst.Nodes.Decl.node with
        | Cst.Nodes.Decl.Package declared -> Some (decl, declared)
        | _ -> None)
      cst.Cst.Nodes.Package.decls
  in
  let first_is_package =
    match cst.Cst.Nodes.Package.decls with
    | { Cst.Nodes.Decl.node = Cst.Nodes.Decl.Package _; _ } :: _ -> true
    | _ -> false
  in
  match package_lines with
  | [] ->
      [
        problem (file_start path)
          (if given then
             Printf.sprintf "a source file must begin with `package %s;`, the name of its package"
               name
           else
             Printf.sprintf
               "a source file must begin with `package %s;`, the name of its \
                directory"
               name);
      ]
  | (first, declared) :: rest ->
      let placement =
        if first_is_package then []
        else
          [
            problem first.Cst.Nodes.Decl.span
              "the `package` declaration must be the first declaration in the \
               file";
          ]
      in
      let mismatch =
        if String.equal declared.Cst.Nodes.Name.text name then []
        else
          [
            problem declared.Cst.Nodes.Name.span
              (Printf.sprintf
                 (if given then
                    "this file is in the package `%s`, so it must declare `package %s;`"
                  else
                    "this file is in the directory `%s`, so it must declare \
                     `package %s;`")
                 name name);
          ]
      in
      let repeated =
        List.map
          (fun ((decl : Cst.Nodes.Decl.t), _) ->
            problem decl.Cst.Nodes.Decl.span
              "a file declares its package once")
          rest
      in
      placement @ mismatch @ repeated

let load_file ~name ~given path =
  match read_file path with
  | exception Sys_error message ->
      Error [ (Diagnostic.in_file path (reason ~path message), []) ]
  | source -> (
      match Cst.parse path source with
      | Error diagnostic -> Error [ (diagnostic, [ (path, source) ]) ]
      | Ok cst -> (
          match check_package_line ~name ~given ~path ~source cst with
          | [] -> Ok { path; source; sst = Sst.of_cst cst }
          | problems -> Error problems))

(* The name of the directory a path leads to, which is the package's name.

   Not the path's last component as written: `.` and `..` name a directory
   without spelling its name, so `--package .` run inside `app` is the package
   `app`. The path is made absolute and those components are resolved first.
   A trailing separator is not part of the name either: `app/` is `app`.
   Symbolic links are not followed; a link to `app` named `lib` is `lib`, the
   same as the directory the link appears to be. *)
let package_name dir =
  let absolute =
    if Filename.is_relative dir then Filename.concat (Sys.getcwd ()) dir
    else dir
  in
  let components =
    List.fold_left
      (fun resolved component ->
        match component with
        | "" | "." -> resolved
        | ".." -> ( match resolved with [] -> [] | _ :: parent -> parent)
        | name -> name :: resolved)
      []
      (String.split_on_char '/' absolute)
  in
  match components with [] -> "" | last :: _ -> last

(* A package the build asks for: its directory, the name its manifest gives
   it, if the driver passed one, and its stamp, if it is a version of a
   published package. *)
type request = { manifest_name : string option; directory : string; stamp : string option }

let name_of request =
  match request.manifest_name with Some name -> name | None -> package_name request.directory

let id_of request = Option.value ~default:"" request.stamp ^ name_of request

let load_package ~is_root request =
  let name = name_of request and id = id_of request and dir = request.directory in
  let given = Option.is_some request.manifest_name in
  if not (Sys.file_exists dir && Sys.is_directory dir) then
    Error [ in_directory dir "no such directory" ]
  else
    match source_files dir with
    | exception Sys_error message ->
        Error [ in_directory dir (reason ~path:dir message) ]
    | [] ->
        Error
          [
            in_directory dir
              (Printf.sprintf "no `%s` files directly in the directory" source_extension);
          ]
    | paths ->
        (* Every file is loaded, whichever fail: one mistake per file is one
           report per file, not one report per run (docs/design/semantics.md D4). *)
        List.map (load_file ~name ~given) paths
        |> all_or_problems
        |> Result.map (fun files -> { id; name; dir; is_root; files; imports = [] })

(* An identity names one package. Two directories with the same one would
   both be that package, and which of them a `name$member` meant would depend
   on nothing the source says. Two versions of one package have two stamps,
   and so two identities. The first directory keeps the identity; each later
   one is reported and not loaded. *)
let claimed_by earlier request =
  let id = id_of request in
  List.find_opt (fun other -> String.equal (id_of other) id) earlier

(* Each key goes to the package that imports by it. Both ends must be
   packages of the build, and a package imports by each key once. *)
let attach_imports packages imports =
  let known id = List.exists (fun p -> String.equal p.id id) packages in
  let problem message = in_directory "." message in
  let unknown (from, key, target) =
    List.filter_map
      (fun id ->
        if known id then None
        else
          Some
            (problem
               (Printf.sprintf "`--import %s:%s=%s` names `%s`, which is no package of the build"
                  from key target id)))
      [ from; target ]
  in
  let twice =
    List.sort_uniq compare (List.map (fun (f, k, _) -> (f, k)) imports)
    |> List.filter_map (fun (from, key) ->
           if List.length (List.filter (fun (f, k, _) -> f = from && k = key) imports) > 1 then
             Some (problem (Printf.sprintf "`%s` is given the key `%s` more than once" from key))
           else None)
  in
  match List.concat_map unknown imports @ twice with
  | [] ->
      Ok
        (List.map
           (fun p ->
             {
               p with
               imports =
                 List.filter_map
                   (fun (from, key, target) ->
                     if String.equal from p.id then Some (key, target) else None)
                   imports;
             })
           packages)
  | problems -> Error problems

(* Problems come out in the order the directories were given, and within a
   directory in file order, so a run reads top to bottom like the command
   that started it. [imports] gives each package's keys, as the importing
   package's identity, the key and the imported package's identity. *)
let assemble_requests ?(imports = []) requests =
  let rec go earlier index = function
    | [] -> []
    | request :: rest ->
        let claimant = claimed_by earlier request in
        let loaded =
          match claimant with
          | Some first ->
              Error
                [
                  in_directory request.directory
                    (Printf.sprintf "the package `%s` is already the directory `%s`" (id_of request)
                       first.directory);
                ]
          | None -> load_package ~is_root:(index = 0) request
        in
        (* Only a directory that got the name claims it, so a third
           duplicate is reported against the first, not the second. *)
        let earlier = if claimant = None then request :: earlier else earlier in
        loaded :: go earlier (index + 1) rest
  in
  let failure problems =
    Error { diagnostics = List.map fst problems; sources = List.concat_map snd problems }
  in
  match all_or_problems (go [] 0 requests) with
  | Error problems -> failure problems
  | Ok packages -> (
      match attach_imports packages imports with
      | Ok packages -> Ok packages
      | Error problems -> failure problems)

(* Each directory named after itself. *)
let assemble dirs =
  assemble_requests
    (List.map (fun directory -> { manifest_name = None; directory; stamp = None }) dirs)

(* The text of every file of the build. *)
let sources packages : Source.Files.t =
  List.concat_map (fun p -> List.map (fun (f : file) -> (f.path, f.source)) p.files) packages

let to_node packages =
  let open Tree_graph in
  group "packages"
  @@ map_seq
    (fun package ->
      group "package"
        (fields
           ((if String.equal package.id package.name then [] else [ ("id", Leaf package.id) ])
           @ [
             ("name", Leaf package.name);
             ("root", Leaf (string_of_bool package.is_root));
             ("dir", Leaf package.dir);
             ("files", map_seq (fun file -> Leaf file.path) package.files);
           ])))
    packages
