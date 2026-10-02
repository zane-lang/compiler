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

   Where the directories come from is the driver's business. Fetching,
   versions and the manifest (dependencies.md) are not modelled; a build is the
   list of directories it was given, and the first of them is the root
   (packages.md §6.1). *)

module Span = Source.Span

type file = {
  path : string;
  (* Kept for rendering a diagnostic against it later: [Diagnostic.render]
     needs the text a span points into. *)
  source : string;
  sst : Sst.Nodes.Package.t;
}

type package = {
  name : string;
  dir : string;
  is_root : bool;
  files : file list;
}

(* What went wrong, and whether there is source to point at.

   Most problems are in a file, and those are ordinary diagnostics. A few are
   about a directory -- missing, unlistable, empty, or named the same as
   another -- and have no text to put a caret under, so they carry only the
   directory. A file that could not be read has no text either, and carries
   only its path. *)
type problem =
  | In_file of { diagnostic : Diagnostic.t; source : string }
  | Unreadable of { path : string; message : string }
  | In_directory of { dir : string; message : string }

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
    In_file { diagnostic = Diagnostic.error span message; source }
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
      Error [ Unreadable { path; message = reason ~path message } ]
  | source -> (
      match Cst.parse path source with
      | Error diagnostic -> Error [ In_file { diagnostic; source } ]
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

(* A package the build asks for: its directory, and the name its manifest
   gives it, if the driver passed one. *)
type request = { manifest_name : string option; directory : string }

let name_of request =
  match request.manifest_name with Some name -> name | None -> package_name request.directory

let load_package ~is_root request =
  let name = name_of request and dir = request.directory in
  let given = Option.is_some request.manifest_name in
  if not (Sys.file_exists dir && Sys.is_directory dir) then
    Error [ In_directory { dir; message = "no such directory" } ]
  else
    match source_files dir with
    | exception Sys_error message ->
        Error [ In_directory { dir; message = reason ~path:dir message } ]
    | [] ->
        Error
          [
            In_directory
              {
                dir;
                message =
                  Printf.sprintf "no `%s` files directly in the directory"
                    source_extension;
              };
          ]
    | paths ->
        (* Every file is loaded, whichever fail: one mistake per file is one
           report per file, not one report per run (docs/design/semantics.md D4). *)
        List.map (load_file ~name ~given) paths
        |> all_or_problems
        |> Result.map (fun files -> { name; dir; is_root; files })

(* A package name names one package. Two directories with the same name would
   both be that package, and which of them a `name$member` meant would depend
   on nothing the source says. Two versions of one package can coexist
   (dependencies.md §11), but by rewriting their symbols at fetch time, which
   is not modelled here. The first directory keeps the name; each later one is
   reported and not loaded. *)
let claimed_by earlier request =
  let name = name_of request in
  List.find_opt (fun other -> String.equal (name_of other) name) earlier

(* Problems come out in the order the directories were given, and within a
   directory in file order, so a run reads top to bottom like the command
   that started it. *)
let assemble_requests requests =
  let rec go earlier index = function
    | [] -> []
    | request :: rest ->
        let claimant = claimed_by earlier request in
        let loaded =
          match claimant with
          | Some first ->
              Error
                [
                  In_directory
                    {
                      dir = request.directory;
                      message =
                        Printf.sprintf
                          "the package `%s` is already the directory `%s`"
                          (name_of request) first.directory;
                    };
                ]
          | None -> load_package ~is_root:(index = 0) request
        in
        (* Only a directory that got the name claims it, so a third
           duplicate is reported against the first, not the second. *)
        let earlier = if claimant = None then request :: earlier else earlier in
        loaded :: go earlier (index + 1) rest
  in
  all_or_problems (go [] 0 requests)

(* Each directory named after itself. *)
let assemble dirs =
  assemble_requests (List.map (fun directory -> { manifest_name = None; directory }) dirs)

let render_problem = function
  | In_file { diagnostic; source } -> Diagnostic.render ~source diagnostic
  (* The same two lines a diagnostic starts with, minus the source excerpt
     there is none of. *)
  | In_directory { dir; message } ->
      Printf.sprintf "Directory \"%s\":\nError: %s\n" dir message
  | Unreadable { path; message } ->
      Printf.sprintf "File \"%s\":\nError: %s\n" path message

let to_node packages =
  let open Tree_graph in
  group "packages"
  @@ map_seq
    (fun package ->
      group "package"
        (fields
           [
             ("name", Leaf package.name);
             ("root", Leaf (string_of_bool package.is_root));
             ("dir", Leaf package.dir);
             ("files", map_seq (fun file -> Leaf file.path) package.files);
           ]))
    packages
