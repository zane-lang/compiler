(* The input to semantics: every package in the build, each one the files of
   its directory, parsed and desugared.

   Stages 1 and 2 never look past a file, so the binary could hand them one.
   Stage 3 cannot work that way. A package is "one order-independent
   compilation unit" made of every file in its directory (packages.md §2.3), a
   name in one file resolves to a declaration in another, and `Int` is a
   declaration in `core`, which is a package like any other. So this is the
   first place files are grouped: by directory, into packages, with the
   directory's basename as the package's name (§2.1). See docs/semantics.md
   §2.

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
   about a directory -- missing, empty, or named the same as another -- and
   have no text to put a caret under, so they carry only the directory. *)
type problem =
  | In_file of { diagnostic : Diagnostic.t; source : string }
  | In_directory of { dir : string; message : string }

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
  Sys.readdir dir |> Array.to_list
  |> List.filter (fun entry ->
         Filename.check_suffix entry source_extension
         && not (Sys.is_directory (Filename.concat dir entry)))
  |> List.sort String.compare
  |> List.map (Filename.concat dir)

let read_file path = In_channel.with_open_bin path In_channel.input_all

(* §2.2: every file "**MUST** begin with a `package packageName` declaration
   whose name exactly matches the basename of the file's directory". The
   grammar accepts a `package` line anywhere at package scope, so "begin with"
   and "exactly one" are both checked here. *)
let check_package_line ~name ~path ~source (cst : Cst.Nodes.Package.t) =
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
          (Printf.sprintf
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
                 "this file is in the directory `%s`, so it must declare \
                  `package %s;`"
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

let load_file ~name path =
  let source = read_file path in
  match Cst.parse path source with
  | Error diagnostic -> Error [ In_file { diagnostic; source } ]
  | Ok cst -> (
      match check_package_line ~name ~path ~source cst with
      | [] -> Ok { path; source; sst = Sst.of_cst cst }
      | problems -> Error problems)

(* The basename of a directory as written, which is the package's name. A
   trailing separator is not part of it: `app/` is the package `app`. *)
let package_name dir = Filename.basename dir

let load_package ~is_root dir =
  let name = package_name dir in
  if not (Sys.file_exists dir && Sys.is_directory dir) then
    Error [ In_directory { dir; message = "no such directory" } ]
  else
    match source_files dir with
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
           report per file, not one report per run (docs/semantics.md D4). *)
        let loaded = List.map (load_file ~name) paths in
        let files = List.filter_map Result.to_option loaded in
        let problems =
          List.concat_map
            (function Ok _ -> [] | Error problems -> problems)
            loaded
        in
        if problems = [] then Ok { name; dir; is_root; files }
        else Error problems

(* A package name names one package. Two directories with the same basename
   would both be that package, and which of them a `name$member` meant would
   depend on nothing the source says. Two versions of one package can coexist
   (dependencies.md §11), but by rewriting their symbols at fetch time, which
   is not modelled here. The first directory keeps the name; each later one is
   reported and not loaded. *)
let claimed_by earlier dir =
  List.find_opt
    (fun other -> String.equal (package_name other) (package_name dir))
    earlier

(* Problems come out in the order the directories were given, and within a
   directory in file order, so a run reads top to bottom like the command
   that started it. *)
let assemble dirs =
  let rec go earlier index = function
    | [] -> []
    | dir :: rest ->
        let claimant = claimed_by earlier dir in
        let loaded =
          match claimant with
          | Some first ->
              Error
                [
                  In_directory
                    {
                      dir;
                      message =
                        Printf.sprintf
                          "the package `%s` is already the directory `%s`"
                          (package_name dir) first;
                    };
                ]
          | None -> load_package ~is_root:(index = 0) dir
        in
        (* Only a directory that got the name claims it, so a third
           duplicate is reported against the first, not the second. *)
        let earlier = if claimant = None then dir :: earlier else earlier in
        loaded :: go earlier (index + 1) rest
  in
  let loaded = go [] 0 dirs in
  match List.concat_map (function Ok _ -> [] | Error p -> p) loaded with
  | [] -> Ok (List.filter_map Result.to_option loaded)
  | problems -> Error problems

let render_problem = function
  | In_file { diagnostic; source } -> Diagnostic.render ~source diagnostic
  (* The same two lines a diagnostic starts with, minus the source excerpt
     there is none of. *)
  | In_directory { dir; message } ->
      Printf.sprintf "Directory \"%s\":\nError: %s\n" dir message

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
