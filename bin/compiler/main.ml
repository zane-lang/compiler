(* Parsing the checked-in sample is the common case while the front end is the
   only stage, so it stays the default when no source is named. *)
let default_path = "test/parser/fixtures/main.zn"

(* Which tree to print. The CST stays the default because it is what the source
   says, and a reader checking the parser wants that one; `--sst` is for
   checking the desugaring, where the interesting thing is what is no longer
   there. *)
type stage = Cst | Sst

(* What the binary was asked to do. One file is enough for the first two
   stages, which never look past it. Semantics takes packages instead
   (docs/semantics.md §2): each `--package DIR` names one, and the first is the
   root.

   A package build prints one of three views: the packages it assembled (the
   default), the declarations with everything passes 1 to 4 resolved about
   them (`--decls`), or the whole typed tree (`--tst`). Past semantics it
   prints the code-generation tree (`--cgt`) or the LLVM module (`--ll`), or
   builds the program into an executable (`--build OUT`,
   docs/lowering.md §7). *)
type view = Assembled | Declarations | Typed | Cgt | Ir | Build of string

type request =
  | File of stage * (string * string)
  | Packages of view * string list

let read_file path =
  try In_channel.with_open_text path In_channel.input_all
  with Sys_error message ->
    prerr_endline message;
    exit 2

let usage () =
  prerr_endline "usage: compiler [--cst|--sst] [SOURCE|-]";
  prerr_endline "       compiler [--decls|--tst|--cgt|--ll] --package DIR [--package DIR ...]";
  prerr_endline "       compiler --build OUT --package DIR [--package DIR ...]";
  exit 2

(* The name reported in parse errors travels with the text, so reading from
   standard input still produces a located message. *)
let read = function
  | "-" -> ("<stdin>", In_channel.input_all In_channel.stdin)
  | path -> (path, read_file path)

let arguments () =
  let rec go stage rest =
    match rest with
    | [] -> File (stage, read default_path)
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
  (* A package build takes nothing but `--package` flags after its view: a
     tree flag or a single source alongside them would ask for two different
     runs at once. *)
  let rec packages view dirs = function
    | [] -> if dirs = [] then usage () else Packages (view, List.rev dirs)
    | "--package" :: dir :: rest -> packages view (dir :: dirs) rest
    | _ -> usage ()
  in
  match List.tl (Array.to_list Sys.argv) with
  | "--package" :: _ as rest -> packages Assembled [] rest
  | "--decls" :: rest -> packages Declarations [] rest
  | "--tst" :: rest -> packages Typed [] rest
  | "--cgt" :: rest -> packages Cgt [] rest
  | "--ll" :: rest -> packages Ir [] rest
  | "--build" :: output :: rest -> packages (Build output) [] rest
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
   wrongly (docs/lowering.md). *)
let generate packages view program =
  match Cgt.lower program with
  | Error (Cgt.Lower.Diagnostic d) ->
      prerr_string (Tst.render_diagnostic packages d);
      exit 1
  | Error (Cgt.Lower.Message m) ->
      prerr_endline ("Error: " ^ m);
      exit 1
  | Ok cgt -> (
      match view with
      | Cgt -> print_string (Tree_graph.render (Cgt.to_node cgt))
      | Ir ->
          let m = Codegen.emit cgt in
          Codegen.prepare m;
          print_string (Codegen.ir m)
      | Build output -> (
          match Codegen.executable (Codegen.emit cgt) output with
          | Ok () -> ()
          | Error message ->
              prerr_endline ("Error: " ^ message);
              exit 1)
      | Assembled | Declarations | Typed -> ())

(* Semantics reports every problem it finds (docs/semantics.md D4) and prints
   no tree when there is one, since a tree with holes in it is not what either
   view promises. *)
let run_packages view dirs =
  match Tst.Assembly.assemble dirs with
  | Error problems ->
      List.iter
        (fun problem -> prerr_string (Tst.Assembly.render_problem problem))
        problems;
      exit 1
  | Ok packages -> (
      match view with
      | Assembled ->
          print_string (Tree_graph.render (Tst.Assembly.to_node packages))
      | Declarations | Typed | Cgt | Ir | Build _ -> (
          let result = Tst.check packages in
          match result.Tst.Semantics.diagnostics with
          | [] -> (
              let program = result.Tst.Semantics.program in
              match view with
              | Declarations | Typed ->
                  print_string (Tree_graph.render (Tst.to_node ~bodies:(view = Typed) program))
              | _ -> generate packages view program)
          | diagnostics ->
              List.iter
                (fun d -> prerr_string (Tst.render_diagnostic packages d))
                diagnostics;
              exit 1))

let () =
  match arguments () with
  | File (stage, input) -> run_file stage input
  | Packages (view, dirs) -> run_packages view dirs
