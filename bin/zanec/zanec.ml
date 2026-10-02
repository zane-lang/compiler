(* Which tree to print. The CST stays the default because it is what the source
   says, and a reader checking the parser wants that one; `--sst` is for
   checking the desugaring, where the interesting thing is what is no longer
   there. *)
type stage = Cst | Sst

(* What the binary was asked to do. One file is enough for the first two
   stages, which never look past it. Semantics takes packages instead
   (docs/design/semantics.md §2): each `--package` names one, and the first
   is the root.

   A package build prints one of three views: the packages it assembled (the
   default), the declarations with everything passes 1 to 4 resolved about
   them (`--decls`), or the whole typed tree (`--tst`). Past semantics it
   prints the code-generation tree (`--cgt`) or the LLVM module (`--ll`), or
   builds the program into an executable (`--build OUT`,
   docs/design/lowering.md §7) or the root package into an object file
   (`--object OUT`, docs/design/separate-compilation.md C3). `--stamp` names
   a package's symbols with its version and identity (C6), and `--link` adds
   a stamped dependency's object to the link (C7). `--check` runs semantics and prints nothing,
   so its exit status and diagnostics are the whole answer. *)
type view = Assembled | Check | Declarations | Typed | Cgt | Ir | Build of string | Object of string

(* What the root package is (packages.md §6.2): an application has a `main`
   to start from, and a library does not become an executable. Without
   `--kind`, `main` is required only to build. A library lowers from every
   function it declares, with its symbols carrying the `!` placeholder
   (docs/design/separate-compilation.md C5). *)
type kind = Application | Library

type build = {
  view : view;
  kind : kind option;
  (* The LLVM target triple to compile for; the host's when absent. *)
  target : string option;
  (* Whether `--ll`, `--build` and `--object` optimize. A program means the same either
     way; an unoptimized build is the faster one to make. *)
  optimize : bool;
  packages : Tst.Assembly.request list;
  (* Each stamped dependency's stamp, and the objects `--build` links with
     the program (docs/design/separate-compilation.md C6, C7). *)
  stamps : (string * string) list;
  link : string list;
}

type request =
  | File of stage * (string * string)
  | Packages of build

let read_file path =
  try In_channel.with_open_text path In_channel.input_all
  with Sys_error message ->
    prerr_endline message;
    exit 2

let usage () =
  prerr_endline "usage: zanec [--cst|--sst] (SOURCE|-)";
  prerr_endline
    "       zanec [--check|--decls|--tst|--cgt|--ll|--build OUT|--object OUT]";
  prerr_endline "             [--kind application|library]";
  prerr_endline
    "             [--target TRIPLE] [--optimize] [--stamp NAME=STAMP ...] [--link FILE ...]";
  prerr_endline "             --package [NAME=]DIR [--package [NAME=]DIR ...]";
  exit 2

(* The name reported in parse errors travels with the text, so reading from
   standard input still produces a located message. *)
let read = function
  | "-" -> ("<stdin>", In_channel.input_all In_channel.stdin)
  | path -> (path, read_file path)

(* A package name as lexical.md §3 spells one: camelCase, so a lowercase
   letter and then letters and digits. *)
let is_package_name name =
  name <> ""
  && (match name.[0] with 'a' .. 'z' -> true | _ -> false)
  && String.for_all (function 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' -> true | _ -> false) name

(* `NAME=DIR` names the package, as its manifest does (packages.md §2.1);
   a bare `DIR` is named after the directory. A path that itself holds a `=`
   is still a path, since what comes before the `=` then is no name. *)
let package_request argument =
  match String.index_opt argument '=' with
  | Some i when is_package_name (String.sub argument 0 i) ->
      {
        Tst.Assembly.manifest_name = Some (String.sub argument 0 i);
        directory = String.sub argument (i + 1) (String.length argument - i - 1);
      }
  | _ -> { Tst.Assembly.manifest_name = None; directory = argument }

let arguments () =
  let rec go stage rest =
    match rest with
    | "--cst" :: rest -> go Cst rest
    | "--sst" :: rest -> go Sst rest
    (* `-` is the stdin source, not an option, so it is taken before the guard
       below rejects everything else that starts with a dash. Without that
       guard a mistyped `--ss` reads as a path, and the error names a file the
       author never meant to open rather than the option they meant to
       write. *)
    | [ "-" ] -> File (stage, read "-")
    | [ source ] when not (String.starts_with ~prefix:"-" source) ->
        File (stage, read source)
    | _ -> usage ()
  in
  (* A package build takes its options in any order, each at most once, and at
     least one `--package`. A tree flag or a single source alongside them would
     ask for two different runs at once. *)
  (* A value never starts with `-`, so a value left out cannot swallow the
     next flag: `--build --package d` is a usage error, not an executable
     named `--package`. *)
  let is_value v = not (String.starts_with ~prefix:"-" v) in
  let rec packages view build = function
    | [] ->
        let view = Option.value view ~default:Assembled in
        if build.packages = [] then usage ()
        else if build.link <> [] && (match view with Build _ -> false | _ -> true) then usage ()
        else
          Packages
            {
              build with
              view;
              packages = List.rev build.packages;
              stamps = List.rev build.stamps;
              link = List.rev build.link;
            }
    | "--package" :: dir :: rest when is_value dir ->
        packages view { build with packages = package_request dir :: build.packages } rest
    | "--kind" :: kind :: rest when build.kind = None && is_value kind ->
        let kind =
          match kind with "application" -> Application | "library" -> Library | _ -> usage ()
        in
        packages view { build with kind = Some kind } rest
    | "--target" :: target :: rest when build.target = None && is_value target ->
        packages view { build with target = Some target } rest
    | "--optimize" :: rest when not build.optimize ->
        packages view { build with optimize = true } rest
    | "--build" :: output :: rest when view = None && is_value output ->
        packages (Some (Build output)) build rest
    | "--object" :: output :: rest when view = None && is_value output ->
        packages (Some (Object output)) build rest
    | "--stamp" :: stamp :: rest when is_value stamp -> (
        match String.index_opt stamp '=' with
        | Some i when i + 1 < String.length stamp ->
            let name = String.sub stamp 0 i in
            if is_package_name name && not (List.mem_assoc name build.stamps) then
              let value = String.sub stamp (i + 1) (String.length stamp - i - 1) in
              packages view { build with stamps = (name, value) :: build.stamps } rest
            else usage ()
        | _ -> usage ())
    | "--link" :: file :: rest when is_value file ->
        packages view { build with link = file :: build.link } rest
    | flag :: rest when view = None -> (
        match flag with
        | "--check" -> packages (Some Check) build rest
        | "--decls" -> packages (Some Declarations) build rest
        | "--tst" -> packages (Some Typed) build rest
        | "--cgt" -> packages (Some Cgt) build rest
        | "--ll" -> packages (Some Ir) build rest
        | _ -> usage ())
    | _ -> usage ()
  in
  let empty =
    {
      view = Assembled;
      kind = None;
      target = None;
      optimize = false;
      packages = [];
      stamps = [];
      link = [];
    }
  in
  match List.tl (Array.to_list Sys.argv) with
  | ( "--package" | "--kind" | "--target" | "--optimize" | "--build" | "--object" | "--stamp"
    | "--link" | "--check" | "--decls" | "--tst" | "--cgt" | "--ll" )
    :: _ as rest ->
      packages None empty rest
  | rest -> go Cst rest

let run_file stage (filename, input) =
  match Cst.parse filename input with
  | Error diagnostic ->
      prerr_string (Diagnostic.render ~source:input diagnostic);
      exit 1
  | Ok cst ->
      let output =
        match stage with
        | Cst -> Cst.to_node cst
        | Sst -> Sst.to_node (Sst.of_cst cst)
      in
      print_string (Tree_graph.render output)

(* Lowering and codegen, once semantics has accepted the program. Lowering
   refuses what it cannot handle yet with a diagnostic rather than lowering it
   wrongly (docs/design/lowering.md). *)
let generate packages build program =
  match Cgt.lower ~library:(build.kind = Some Library) ~stamps:build.stamps program with
  | Error (Cgt.Lower.Diagnostic d) ->
      prerr_string (Tst.render_diagnostic packages d);
      exit 1
  | Error (Cgt.Lower.Message m) ->
      prerr_endline ("Error: " ^ m);
      exit 1
  | Ok cgt -> (
      let fail message =
        prerr_endline ("Error: " ^ message);
        exit 1
      in
      match build.view with
      | Cgt -> print_string (Tree_graph.render (Cgt.to_node cgt))
      | Ir -> (
          let m = Codegen.emit cgt in
          match Codegen.prepare ?target:build.target ~optimize:build.optimize m with
          | Ok () -> print_string (Codegen.ir m)
          | Error message -> fail message)
      | Build output -> (
          match
            Codegen.executable ?target:build.target ~optimize:build.optimize ~link:build.link
              (Codegen.emit cgt) output
          with
          | Ok () -> ()
          | Error message -> fail message)
      | Object output -> (
          match
            Codegen.object_file ?target:build.target ~optimize:build.optimize (Codegen.emit cgt)
              output
          with
          | Ok () -> ()
          | Error message -> fail message)
      | Assembled | Check | Declarations | Typed -> ())

(* An application starts from `main` (packages.md §6.2), so one without it is
   an error however far the build goes. Without `--kind`, lowering still
   refuses to build a root with no `main`; this says so as soon as semantics
   has run, and for `--check` too. *)
let check_kind build (program : Tst.Nodes.Program.t) =
  match (build.kind, program.Tst.Nodes.Program.packages) with
  | Some Application, root :: _ ->
      let declares_main =
        List.exists
          (fun (d : Tst.Nodes.Decl.t) ->
            match d.Tst.Nodes.Decl.node with
            | Tst.Nodes.Decl.Verb { signature; _ } -> signature.Tst.Signature.name = "main"
            | _ -> false)
          root.Tst.Nodes.Package.decls
      in
      if not declares_main then begin
        prerr_endline
          (Printf.sprintf "Error: the application `%s` declares no `main` to start from"
             root.Tst.Nodes.Package.name);
        exit 1
      end
  | _ -> ()

(* Semantics reports every problem it finds (docs/design/semantics.md D4) and
   prints no tree when there is one, since a tree with holes in it is not what
   either view promises. *)
let run_packages build =
  (match (build.kind, build.view) with
  | Some Library, Build _ ->
      prerr_endline "Error: a library is not built into an executable; check it with `--check`";
      exit 1
  | _ -> ());
  match Tst.Assembly.assemble_requests build.packages with
  | Error problems ->
      List.iter
        (fun problem -> prerr_string (Tst.Assembly.render_problem problem))
        problems;
      exit 1
  | Ok packages -> (
      match build.view with
      | Assembled ->
          print_string (Tree_graph.render (Tst.Assembly.to_node packages))
      | Check | Declarations | Typed | Cgt | Ir | Build _ | Object _ -> (
          let result = Tst.check packages in
          match result.Tst.Semantics.diagnostics with
          | [] -> (
              let program = result.Tst.Semantics.program in
              check_kind build program;
              match build.view with
              | Check -> ()
              | Declarations | Typed ->
                  print_string
                    (Tree_graph.render (Tst.to_node ~bodies:(build.view = Typed) program))
              | _ -> generate packages build program)
          | diagnostics ->
              List.iter
                (fun d -> prerr_string (Tst.render_diagnostic packages d))
                diagnostics;
              exit 1))

let () =
  match arguments () with
  | File (stage, input) -> run_file stage input
  | Packages build -> run_packages build
