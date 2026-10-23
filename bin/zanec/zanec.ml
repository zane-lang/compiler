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
   `--link` adds a stamped dependency's object to the link (C7). A tiered
   build (docs/design/tiers.md) is two: `--build OUT --tiered` makes tier
   0, and `--tier-up OUT` tier 1, the shared library tier 0 loads while it
   runs. `--check`
   runs semantics and prints nothing, so its exit status and diagnostics are
   the whole answer. *)
type view = Assembled | Check | Declarations | Typed | Cgt | Ir | Build of string | Object of string | Tier_up of string

(* Whether the build has a root package (packages.md §6.1): `--root` makes
   the first package the root, which has a `main` to start from (§6.2), and
   `--no-root` gives the build none, so it does not become an executable.
   Without either, the first package is the root and `main` is required only
   to build. A build without a root lowers from every function it declares,
   with its symbols carrying the `!` placeholder
   (docs/design/separate-compilation.md C5). *)
type build = {
  view : view;
  root : bool option;
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
  (* The size of each context's range of frames, which `zane` takes from the
     root manifest (memory.md §3.1, dependencies.md §2.1). *)
  regions : Driver.regions;
  (* Whether small aggregates cross calls as packed words
     (docs/design/lowering.md §9): a measured experiment, off by default. *)
  pack : bool;
  (* Whether calls are remembered while the program runs (Cgt.Memo): on
     unless `--no-memoize`. *)
  memoize : bool;
  (* Whether `--build` makes tier 0 of a tiered build. *)
  tiered : bool;
}

(* `--rewrite STAMP INPUT OUTPUT` is fetching's step, not a build's: a
   library's object, built under the `!` placeholder, written out with the
   placeholder turned into the stamp (docs/design/separate-compilation.md
   C9). `--remap FROM TO INPUT OUTPUT` is remapping's: an object written out
   with its references to one version of a package moved to another (C11).
   `--bundle-runtime DIR --target TRIPLE [--optimize]` is a release's: the
   runtime compiled for a target into the toolchain's directory of them
   (docs/design/lowering.md §7). *)
type request =
  | File of stage * (string * string)
  | Packages of build
  | Rewrite of { stamp : string; input : string; output : string }
  | Remap of { from : string; to_ : string; input : string; output : string }
  | Bundle_runtime of { dir : string; target : string; optimize : bool }

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
    "       zanec [--check|--decls|--tst|--cgt|--ll|--build OUT [--tiered]|--object OUT|--tier-up OUT]";
  prerr_endline "             [--root|--no-root]";
  prerr_endline
    "             [--target TRIPLE] [--optimize] [--stamp PATH=STAMP ...] [--link FILE ...]";
  prerr_endline "             [--fixed-region BYTES] [--spawned-fixed-region BYTES] [--pack-aggregates] [--no-memoize]";
  prerr_endline "             [--import PACKAGE:KEY=PACKAGE ...]";
  prerr_endline "             --package [[STAMP]PATH=]DIR [--package [[STAMP]PATH=]DIR ...]";
  prerr_endline "       zanec --rewrite STAMP INPUT OUTPUT";
  prerr_endline "       zanec --remap FROM TO INPUT OUTPUT";
  prerr_endline "       zanec --bundle-runtime DIR --target TRIPLE [--optimize]"

(* The name reported in parse errors travels with the text, so reading from
   standard input still produces a located message. *)
let read = function
  | "-" -> ("<stdin>", In_channel.input_all In_channel.stdin)
  | path -> (path, read_file path)

(* A package name as lexical.md §3 spells one: camelCase, so a lowercase
   letter and then letters and digits, after a leading `_` when the package
   is private to its project (§4.2, packages.md §4.4). Letters are Unicode
   ones, as in source, so the lexer itself decides. *)
let is_package_name = Cst.is_lower_identifier

(* A range of frames is a whole number of MiB, at least one, since the
   runtime makes it usable a MiB at a time. *)
let region_size bytes =
  match int_of_string_opt bytes with
  | Some n when String.for_all (function '0' .. '9' -> true | _ -> false) bytes
                && n >= 1 lsl 20 && n mod (1 lsl 20) = 0 ->
      n
  | _ -> usage ()

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
        (* Tier 0 is a build, and neither tier is the optimized build of
           `--optimize`: tier 1 makes its own (docs/design/tiers.md). *)
        else if build.tiered && ((match view with Build _ -> false | _ -> true) || build.optimize) then usage ()
        else if (match view with Tier_up _ -> true | _ -> false) && build.optimize then usage ()
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
    | "--root" :: rest when build.root = None -> packages view { build with root = Some true } rest
    | "--no-root" :: rest when build.root = None -> packages view { build with root = Some false } rest
    | "--target" :: target :: rest when build.target = None && is_value target ->
        packages view { build with target = Some target } rest
    | "--optimize" :: rest when not build.optimize ->
        packages view { build with optimize = true } rest
    | "--pack-aggregates" :: rest when not build.pack -> packages view { build with pack = true } rest
    | "--no-memoize" :: rest when build.memoize -> packages view { build with memoize = false } rest
    | "--tiered" :: rest when not build.tiered -> packages view { build with tiered = true } rest
    | "--tier-up" :: output :: rest when view = None && is_value output ->
        packages (Some (Tier_up output)) build rest
    | "--build" :: output :: rest when view = None && is_value output ->
        packages (Some (Build output)) build rest
    | "--object" :: output :: rest when view = None && is_value output ->
        packages (Some (Object output)) build rest
    | "--stamp" :: stamp :: rest when is_value stamp -> (
        match String.index_opt stamp '=' with
        | Some i when i + 1 < String.length stamp ->
            let name = String.sub stamp 0 i
            and value = String.sub stamp (i + 1) (String.length stamp - i - 1) in
            if is_package_path name && Rewrite.is_stamp value && not (List.mem_assoc name build.stamps)
            then packages view { build with stamps = (name, value) :: build.stamps } rest
            else usage ()
        | _ -> usage ())
    | "--link" :: file :: rest when is_value file ->
        packages view { build with link = file :: build.link } rest
    | "--fixed-region" :: bytes :: rest when build.regions.fixed = None ->
        packages view { build with regions = { build.regions with fixed = Some (region_size bytes) } } rest
    | "--spawned-fixed-region" :: bytes :: rest when build.regions.spawned = None ->
        packages view
          { build with regions = { build.regions with spawned = Some (region_size bytes) } }
          rest
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
      root = None;
      target = None;
      optimize = false;
      packages = [];
      stamps = [];
      link = [];
      imports = [];
      regions = { Driver.fixed = None; spawned = None };
      pack = false;
      memoize = true;
      tiered = false;
    }
  in
  match List.tl (Array.to_list Sys.argv) with
  | [ "--rewrite"; stamp; input; output ] when List.for_all is_value [ stamp; input; output ] ->
      Rewrite { stamp; input; output }
  | [ "--remap"; from; to_; input; output ]
    when List.for_all is_value [ from; to_; input; output ] ->
      Remap { from; to_; input; output }
  | [ "--bundle-runtime"; dir; "--target"; target ] when List.for_all is_value [ dir; target ] ->
      Bundle_runtime { dir; target; optimize = false }
  | [ "--bundle-runtime"; dir; "--target"; target; "--optimize" ] when List.for_all is_value [ dir; target ] ->
      Bundle_runtime { dir; target; optimize = true }
  | ( "--package" | "--root" | "--no-root" | "--target" | "--optimize" | "--build" | "--object" | "--stamp"
    | "--link" | "--import" | "--fixed-region" | "--spawned-fixed-region" | "--pack-aggregates" | "--no-memoize" | "--check"
    | "--tiered" | "--tier-up"
    | "--decls" | "--tst" | "--cgt" | "--ll" )
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
  let* cgt =
    Driver.lower ~regions:build.regions
      ~root:(Option.value build.root ~default:true)
      packages program
  in
  let target = build.target and optimize = build.optimize and pack = build.pack and memoize = build.memoize in
  let cgt = Driver.optimize ~optimize cgt in
  match build.view with
  | Cgt ->
      print_string (Tree_graph.render (Cgt.to_node cgt));
      Ok ()
  | Ir ->
      let* ir = Driver.ir ?target ~pack ~memoize ~regions:build.regions ~optimize cgt in
      print_string ir;
      Ok ()
  | Build output ->
      Driver.executable ?target ~pack ~memoize ~regions:build.regions ~tiered:build.tiered ~optimize ~link:build.link cgt
        output
  | Tier_up output -> Driver.tier_up ?target ~pack ~memoize ~regions:build.regions cgt output
  | Object output -> Driver.object_file ?target ~pack ~memoize ~regions:build.regions ~optimize cgt output
  | Assembled | Check | Declarations | Typed -> Ok ()

(* Without `--root` or `--no-root`, the root needs its `main` once it is
   lowered, since lowering starts from it. *)
let needs_main build =
  match (build.root, build.view) with
  | Some true, _ | None, (Cgt | Ir | Build _ | Object _ | Tier_up _) -> true
  | Some false, _ | None, (Assembled | Check | Declarations | Typed) -> false

(* Semantics prints no tree when it found a problem, since a tree with holes
   in it is not what either view promises. *)
let run_packages build =
  let* () = match build.view with Build _ | Tier_up _ -> Driver.buildable build.root | _ -> Ok () in
  let root = Option.value build.root ~default:true in
  let* packages =
    Driver.assemble ~root ~imports:build.imports ~stamps:build.stamps build.packages
  in
  match build.view with
  | Assembled ->
      print_string (Tree_graph.render (Tst.Assembly.to_node packages));
      Ok ()
  | Check | Declarations | Typed | Cgt | Ir | Build _ | Object _ | Tier_up _ -> (
      let* program = Driver.check packages in
      let* () = if needs_main build then Driver.require_main program else Ok () in
      match build.view with
      | Check -> Ok ()
      | Declarations | Typed ->
          print_string (Tree_graph.render (Tst.to_node ~bodies:(build.view = Typed) program));
          Ok ()
      | _ -> generate packages build program)

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
            Driver.rewrite_object ~random:(Random.State.make_self_init ()) ~stamps:[ stamp ]
              ~rewrite:(Rewrite.rewrite ~stamp) ~input ~output
        | Remap { from; to_; input; output } ->
            Driver.rewrite_object ~random:(Random.State.make_self_init ()) ~stamps:[ from; to_ ]
              ~rewrite:(Rewrite.remap ~from ~to_) ~input ~output
        | Bundle_runtime { dir; target; optimize } -> Driver.bundle_runtime ~target ~optimize dir
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
