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
   (`--object OUT`, docs/design/separate-compilation.md C3). A package's
   stamp names its symbols with its version and identity (C6), `--import`
   says which package each of a package's import keys names (C10), and
   `--link` adds a stamped dependency's object to the link (C7). `--check`
   runs semantics and prints nothing, so its exit status and diagnostics are
   the whole answer. *)
type view = Assembled | Check | Declarations | Typed | Cgt | Ir | Build of string | Object of string

(* What the root package is (packages.md §6.2): an application has a `main`
   to start from, and a library does not become an executable. Without
   `--kind`, `main` is required only to build. A library lowers from every
   function it declares, with its symbols carrying the `!` placeholder
   (docs/design/separate-compilation.md C5). *)
type kind = Driver.kind = Application | Library

type build = {
  view : view;
  kind : kind option;
  (* The LLVM target triple to compile for; the host's when absent. *)
  target : string option;
  (* Whether `--cgt`, `--ll`, `--build` and `--object` optimize. A program means the
     same either way; an unoptimized build is the faster one to make. *)
  optimize : bool;
  packages : Tst.Assembly.request list;
  (* Stamps given by package name, the objects `--build` links with the
     program, and each package's import keys, as the importing package, the
     key and the imported package (docs/design/separate-compilation.md C6,
     C7, C10). *)
  stamps : (string * string) list;
  link : string list;
  imports : (string * string * string) list;
}

(* `--rewrite STAMP INPUT OUTPUT` is fetching's step, not a build's: a
   library's object, built under the `!` placeholder, written out with the
   placeholder turned into the stamp (docs/design/separate-compilation.md
   C9). `--remap FROM TO INPUT OUTPUT` is remapping's: an object written out
   with its references to one version of a package moved to another (C11). *)
type request =
  | File of stage * (string * string)
  | Packages of build
  | Rewrite of { stamp : string; input : string; output : string }
  | Remap of { from : string; to_ : string; input : string; output : string }

(* A command the binary cannot run: the arguments do not say a run it
   knows, or a source it names cannot be read. Exits with status 2. *)
exception Usage of string option

let read_file path =
  try In_channel.with_open_text path In_channel.input_all
  with Sys_error message -> raise (Usage (Some message))

let usage () = raise (Usage None)

let print_usage () =
  prerr_endline "usage: zanec [--cst|--sst] (SOURCE|-)";
  prerr_endline
    "       zanec [--check|--decls|--tst|--cgt|--ll|--build OUT|--object OUT]";
  prerr_endline "             [--kind application|library]";
  prerr_endline
    "             [--target TRIPLE] [--optimize] [--stamp PATH=STAMP ...] [--link FILE ...]";
  prerr_endline "             [--import PACKAGE:KEY=PACKAGE ...]";
  prerr_endline "             --package [[STAMP]PATH=]DIR [--package [[STAMP]PATH=]DIR ...]";
  prerr_endline "       zanec --rewrite STAMP INPUT OUTPUT";
  prerr_endline "       zanec --remap FROM TO INPUT OUTPUT"

(* The name reported in parse errors travels with the text, so reading from
   standard input still produces a located message. *)
let read = function
  | "-" -> ("<stdin>", In_channel.input_all In_channel.stdin)
  | path -> (path, read_file path)

(* A package name as lexical.md §3 spells one: camelCase, so a lowercase
   letter and then letters and digits, after a leading `_` when the package
   is private to its project (§4.2, packages.md §4.4). *)
let is_package_name name =
  let rest =
    if String.starts_with ~prefix:"_" name then String.sub name 1 (String.length name - 1) else name
  in
  rest <> ""
  && (match rest.[0] with 'a' .. 'z' -> true | _ -> false)
  && String.for_all (function 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' -> true | _ -> false) rest

(* A package's path within its project's `lib/`: its directory names joined
   by `.`, as `gui.opengl` for a subpackage (dependencies.md §6.1). *)
let is_package_path path = List.for_all is_package_name (String.split_on_char '.' path)

(* A package as `--package` and `--import` name it: its path, after its
   stamp when it has one, as `v1.0.1%3f9a1c02b7e4d6a8%gui.opengl`. *)
let package_id id =
  match String.rindex_opt id '%' with
  | None -> if is_package_path id then Some (None, id) else None
  | Some i ->
      let stamp = String.sub id 0 (i + 1)
      and path = String.sub id (i + 1) (String.length id - i - 1) in
      if Rewrite.is_stamp stamp && is_package_path path then Some (Some stamp, path) else None

(* `PATH=DIR` names the package by its path, whose last part is the name
   its files declare (packages.md §2.2), and `STAMPPATH=DIR` gives it its
   stamp as well; a bare `DIR` is named after the directory. A path that
   itself holds a `=` is still a path, since what comes before the `=` then
   is no name. *)
let package_request argument =
  let whole = { Tst.Assembly.manifest_name = None; directory = argument; stamp = None } in
  match String.index_opt argument '=' with
  | Some i -> (
      match package_id (String.sub argument 0 i) with
      | Some (stamp, name) ->
          {
            Tst.Assembly.manifest_name = Some name;
            directory = String.sub argument (i + 1) (String.length argument - i - 1);
            stamp;
          }
      | None -> whole)
  | None -> whole

(* `PACKAGE:KEY=PACKAGE`: the package that imports, the key it imports by,
   and the package the key names (dependencies.md §8). *)
let import_request argument =
  match (String.index_opt argument ':', String.index_opt argument '=') with
  | Some colon, Some equals when colon < equals ->
      let from = String.sub argument 0 colon
      and key = String.sub argument (colon + 1) (equals - colon - 1)
      and target = String.sub argument (equals + 1) (String.length argument - equals - 1) in
      if package_id from <> None && is_package_name key && package_id target <> None then
        Some (from, key, target)
      else None
  | _ -> None

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
              imports = List.rev build.imports;
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
            if is_package_path name && not (List.mem_assoc name build.stamps) then
              let value = String.sub stamp (i + 1) (String.length stamp - i - 1) in
              packages view { build with stamps = (name, value) :: build.stamps } rest
            else usage ()
        | _ -> usage ())
    | "--link" :: file :: rest when is_value file ->
        packages view { build with link = file :: build.link } rest
    | "--import" :: import :: rest when is_value import -> (
        match import_request import with
        | Some i -> packages view { build with imports = i :: build.imports } rest
        | None -> usage ())
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
      imports = [];
    }
  in
  match List.tl (Array.to_list Sys.argv) with
  | [ "--rewrite"; stamp; input; output ] when List.for_all is_value [ stamp; input; output ] ->
      Rewrite { stamp; input; output }
  | [ "--remap"; from; to_; input; output ]
    when List.for_all is_value [ from; to_; input; output ] ->
      Remap { from; to_; input; output }
  | ( "--package" | "--kind" | "--target" | "--optimize" | "--build" | "--object" | "--stamp"
    | "--link" | "--import" | "--check" | "--decls" | "--tst" | "--cgt" | "--ll" )
    :: _ as rest ->
      packages None empty rest
  | rest -> go Cst rest

let run_file stage (filename, input) =
  match Cst.parse filename input with
  | Error diagnostic -> Driver.fail ~sources:[ (filename, input) ] [ diagnostic ]
  | Ok cst ->
      let output =
        match stage with
        | Cst -> Cst.to_node cst
        | Sst -> Sst.to_node (Sst.of_cst cst)
      in
      print_string (Tree_graph.render output);
      Ok ()

let ( let* ) = Result.bind

(* Lowering and codegen, once semantics has accepted the program. *)
let generate packages build program =
  let* cgt = Driver.lower ~optimize:build.optimize ~kind:(Option.value build.kind ~default:Application) packages program in
  let target = build.target and optimize = build.optimize in
  let cgt = Driver.optimize ~optimize cgt in
  match build.view with
  | Cgt ->
      print_string (Tree_graph.render (Cgt.to_node cgt));
      Ok ()
  | Ir ->
      let* ir = Driver.ir ?target ~optimize cgt in
      print_string ir;
      Ok ()
  | Build output -> Driver.executable ?target ~optimize ~link:build.link cgt output
  | Object output -> Driver.object_file ?target ~optimize cgt output
  | Assembled | Check | Declarations | Typed -> Ok ()

(* Without `--kind`, a root is an application once it is lowered, since
   lowering starts from its `main`. *)
let needs_main build =
  match (build.kind, build.view) with
  | Some Application, _ | None, (Cgt | Ir | Build _ | Object _) -> true
  | Some Library, _ | None, (Assembled | Check | Declarations | Typed) -> false

(* Semantics prints no tree when it found a problem, since a tree with holes
   in it is not what either view promises. *)
let run_packages build =
  let* () = match build.view with Build _ -> Driver.buildable build.kind | _ -> Ok () in
  let root = Option.value build.kind ~default:Application = Application in
  let* packages =
    Driver.assemble ~root ~imports:build.imports ~stamps:build.stamps build.packages
  in
  match build.view with
  | Assembled ->
      print_string (Tree_graph.render (Tst.Assembly.to_node packages));
      Ok ()
  | Check | Declarations | Typed | Cgt | Ir | Build _ | Object _ -> (
      let* program = Driver.check packages in
      let* () = if needs_main build then Driver.require_main program else Ok () in
      match build.view with
      | Check -> Ok ()
      | Declarations | Typed ->
          print_string (Tree_graph.render (Tst.to_node ~bodies:(build.view = Typed) program));
          Ok ()
      | _ -> generate packages build program)

(* The output is written only once the whole object has been rewritten, so a
   malformed input leaves nothing behind. It is written beside OUTPUT and
   renamed into place, so a failed write leaves an existing OUTPUT, or the
   INPUT it may be, as it was. *)
let run_rewrite ~stamps ~rewrite ~input ~output =
  let fail message = Driver.fail [ Diagnostic.about_invocation message ] in
  let not_stamp stamp =
    Printf.sprintf
      "`%s` is not a stamp: a version tag of letters, digits, `.`, `_`, `+` and `-`, then `%%`, 16 lowercase hexadecimal digits and `%%`"
      stamp
  in
  match List.find_opt (fun stamp -> not (Rewrite.is_stamp stamp)) stamps with
  | Some stamp -> fail (not_stamp stamp)
  | None -> (
      match stamps with
      | [ from; to_ ] when not (Rewrite.same_package from to_) ->
          fail
            (Printf.sprintf
               "`%s` and `%s` are versions of two packages, since their identity hashes differ; \
                remapping moves references between versions of one package"
               from to_)
      | _ -> (
          match In_channel.with_open_bin input In_channel.input_all with
          | exception Sys_error message -> fail message
          | contents -> (
              match rewrite contents with
              | Error message -> fail (input ^ ": " ^ message)
              | Ok (rewritten, _) -> (
                  Random.self_init ();
                  let temporary =
                    Filename.concat (Filename.dirname output)
                      (Printf.sprintf ".%s.%08x" (Filename.basename output) (Random.bits ()))
                  in
                  try
                    Out_channel.with_open_gen
                      [ Open_wronly; Open_creat; Open_excl; Open_binary ]
                      0o666 temporary
                      (fun oc -> output_string oc rewritten);
                    Sys.rename temporary output;
                    Ok ()
                  with Sys_error message ->
                    (try Sys.remove temporary with Sys_error _ -> ());
                    fail (Printf.sprintf "cannot write `%s`: %s" output message)))))

(* The one place the binary exits: 0 when the run did what it was asked,
   1 when the compiler refused the program, 2 for a command it cannot run,
   and 3 for a broken invariant, the compiler's own fault. Any other
   exception that escapes a stage broke an invariant too. *)
let () =
  let internal ?span message =
    prerr_string (Diagnostic.render_internal ?span message);
    3
  in
  let status =
    try
      let result =
        match arguments () with
        | File (stage, input) -> run_file stage input
        | Packages build -> run_packages build
        | Rewrite { stamp; input; output } ->
            run_rewrite ~stamps:[ stamp ] ~rewrite:(Rewrite.rewrite ~stamp) ~input ~output
        | Remap { from; to_; input; output } ->
            run_rewrite ~stamps:[ from; to_ ] ~rewrite:(Rewrite.remap ~from ~to_) ~input ~output
      in
      match result with
      | Ok () -> 0
      | Error failure ->
          List.iter prerr_string (Driver.render failure);
          1
    with
    | Usage message ->
        (match message with Some m -> prerr_endline m | None -> print_usage ());
        2
    | Diagnostic.Internal { span; message } -> internal ?span message
    | Stack_overflow -> internal "the stack overflowed"
    | e ->
        (* With OCAMLRUNPARAM=b, where it was raised. *)
        let backtrace = Printexc.get_backtrace () in
        internal
          (if backtrace = "" then Printexc.to_string e else Printexc.to_string e ^ "\n" ^ backtrace)
  in
  exit status
