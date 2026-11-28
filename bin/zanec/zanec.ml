(* Which tree to print. The CST stays the default because it matches the source
   as written, and a reader checking the parser wants that tree; `--sst` is for
   checking the desugaring, where the interesting part is the syntax that is no
   longer there. *)
type stage = Cst | Sst

open Driver.Build_flags

(* The request the binary was asked to carry out. One file is enough for the
   first two stages, which never look past that file. Semantics takes
   packages instead, which `Driver.Build_flags` reads from the flags of a
   package build. `--lsp` serves the language server over standard input and
   output (docs/design/language-server.md); `--zane PATH` names the `zane`
   that lists a project's builds.

   `--rewrite STAMP INPUT OUTPUT` is a step of fetching, not of a build: it
   writes out a library's object, built under the `!` placeholder, with the
   placeholder turned into the stamp (docs/design/separate-compilation.md
   C9), and rewrites the file of C module hashes beside the object the same
   way (docs/design/ffi.md F15). `--remap FROM TO INPUT OUTPUT` is the step of remapping: it
   writes out an object with its references to one version of a package
   moved to another version (C11). `--bundle-runtime DIR --target TRIPLE
   [--optimize]` is a step of a release: it compiles the runtime for a target
   into the toolchain's directory of runtimes (docs/design/lowering.md §7). *)
type request =
  | File of stage * (string * string)
  | Packages of Driver.Build_flags.t
  | Lsp of string option
  | Rewrite of { stamp : string; input : string; output : string }
  | Remap of { from : string; to_ : string; input : string; output : string }
  | Bundle_runtime of { dir : string; target : string; optimize : bool }

(* A command the binary cannot run: the arguments form no [request], or a
   source file they name cannot be read. Exits with status 2. *)
exception Usage of string option

let read_file path =
  try In_channel.with_open_text path In_channel.input_all
  with Sys_error message -> raise (Usage (Some message))

let usage () = raise (Usage None)

(* A value never starts with `-`, so a value left out cannot swallow the
   next flag. *)
let is_value v = not (String.starts_with ~prefix:"-" v)

let print_usage () =
  prerr_endline "usage: zanec [--cst|--sst] (SOURCE|-)";
  prerr_endline
    "       zanec [--check|--decls|--tst|--cgt|--ll|--build OUT [--tiered]|--library OUT|--object OUT|--tier-up OUT";
  prerr_endline "              |--compile-commands OUT|--write-backs OUT]";
  prerr_endline "             [--root|--no-root] [--program-write-backs FILE] [--comptime-readings FILE]";
  prerr_endline
    "             [--target TRIPLE] [--optimize] [--stamp PATH=STAMP ...] [--link FILE ...] [--c-hashes FILE ...]";
  prerr_endline "             [--fixed-region BYTES] [--spawned-fixed-region BYTES] [--pack-aggregates] [--no-memoize]";
  prerr_endline "             [--import PACKAGE:KEY=PACKAGE ...] [--build-argument ARGUMENT ...]";
  prerr_endline "             --package [[STAMP]PATH=]DIR [--package [[STAMP]PATH=]DIR ...]";
  prerr_endline "       zanec --lsp [--zane PATH]";
  prerr_endline "       zanec --rewrite STAMP INPUT OUTPUT";
  prerr_endline "       zanec --remap FROM TO INPUT OUTPUT";
  prerr_endline "       zanec --bundle-runtime DIR --target TRIPLE [--optimize]"

(* The name reported in parse errors travels with the text, so reading from
   standard input still produces a located message. *)
let read = function
  | "-" -> ("<stdin>", In_channel.input_all In_channel.stdin)
  | path -> (path, read_file path)

let arguments () =
  let rec go stage rest =
    match rest with
    | "--cst" :: rest -> go Cst rest
    | "--sst" :: rest -> go Sst rest
    (* `-` is the stdin source, not an option, so it is taken before the guard
       below rejects everything else that starts with a dash. Without that
       guard a mistyped `--ss` reads as a path, and the error names a file the
       author never meant to open rather than the mistyped option. *)
    | [ "-" ] -> File (stage, read "-")
    | [ source ] when not (String.starts_with ~prefix:"-" source) ->
        File (stage, read source)
    | _ -> usage ()
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
  | [ "--lsp" ] -> Lsp None
  | [ "--lsp"; "--zane"; zane ] when is_value zane -> Lsp (Some zane)
  | flag :: _ as rest when Driver.Build_flags.starts flag -> (
      try Packages (Driver.Build_flags.parse rest) with Driver.Build_flags.Usage -> usage ())
  | rest -> go Cst rest

let run_file stage (filename, input) =
  match Cst.parse_recovering filename input with
  | _, (_ :: _ as diagnostics) -> Driver.fail ~sources:[ (filename, input) ] diagnostics
  | cst, [] ->
      let output =
        match stage with
        | Cst -> Cst.to_node cst
        | Sst -> Sst.to_node (Sst.of_cst cst)
      in
      print_string (Tree_graph.render output);
      Ok ()

let ( let* ) = Result.bind

(* Lowering and codegen, once semantics has accepted the program. *)
let generate ~plugin packages c_code build program =
  let* () = match build.view with Object output -> Driver.check_object_output output | _ -> Ok () in
  let root = Option.value build.root ~default:true in
  let target = build.target and optimize = build.optimize and pack = build.pack and memoize = build.memoize in
  (* Only an optimized build retains a dependency's C (docs/design/ffi.md
     F13), so only an optimized build given the dependency's hashes writes
     the glue again to compare it. *)
  let compare_glue = optimize && build.c_hashes <> [] in
  let* cgt =
    Driver.lower ~regions:build.regions ~compare_glue ?program_write_backs:build.program_write_backs ~plugin ~root packages
      program
  in
  (* The C is made from the lowered tree, whose thunks and function values
     stage 5 keeps. An optimized build makes the C before stage 5, since
     stage 5 folds calls into the C (docs/design/ffi.md F16). *)
  let c_of cgt =
    let* hashes = Driver.read_hashes build.c_hashes in
    let hashes = if compare_glue then hashes else [] in
    Driver.c_modules ?target ~link:build.link ~hashes ~plugin ~root packages c_code cgt
  in
  (* A call marked `comptime` runs in every build, and may call into C, so
     a build with one makes the C before evaluating it. *)
  let marked = cgt.Cgt.Nodes.Program.comptime <> [] in
  let* made = if optimize || marked then Result.map Option.some (c_of cgt) else Ok None in
  let readings =
    Option.map
      (fun file -> match build.view with Tier_up _ -> Driver.Replay file | _ -> Driver.Record file)
      build.comptime_readings
  in
  let* cgt, read_arguments =
    Driver.comptime ?target ?c:made ?readings ~arguments:build.build_arguments packages cgt
  in
  let* cgt = Driver.optimize ?target ?c:(if optimize then made else None) ~optimize cgt in
  let c () = match made with Some c -> Ok c | None -> c_of cgt in
  match build.view with
  | Cgt ->
      print_string (Tree_graph.render (Cgt.to_node cgt));
      Ok ()
  | Ir ->
      let* c = c () in
      let* ir = Driver.ir ?target ~pack ~memoize ~c ~regions:build.regions ~optimize cgt in
      print_string ir;
      Ok ()
  | Library output ->
      let* c = c () in
      Driver.library ?target ~pack ~memoize ~c ~regions:build.regions ~optimize ~link:build.link cgt output
  | Build output ->
      let* c = c () in
      Driver.executable ?target ~pack ~memoize ~c ~regions:build.regions ~tiered:build.tiered ~optimize
        ~link:build.link cgt output
  | Tier_up output ->
      let* c = c () in
      Driver.tier_up ?target ~pack ~memoize ~c ~regions:build.regions cgt output
  | Object output ->
      let* c = c () in
      let* () = Driver.object_file ?target ~pack ~memoize ~c ~regions:build.regions ~optimize cgt output in
      let* () = Driver.write_hashes ~output (Driver.hashes_of packages c_code c) in
      Driver.write_arguments_marker ~output ~read:read_arguments
  | Assembled | Check | Declarations | Typed | Compile_commands _ | Write_backs _ -> Ok ()

(* Without `--root` or `--no-root`, the root needs its `main`, or the
   exports of a plugin package, once the program is lowered, since lowering
   starts from them (packages.md §8.1). *)
let needs_entry build =
  match (build.root, build.view) with
  | Some true, _ | None, (Cgt | Ir | Build _ | Library _ | Object _ | Tier_up _ | Write_backs _) -> true
  | Some false, _ | None, (Assembled | Check | Declarations | Typed | Compile_commands _) -> false

(* What the view builds the root into. *)
let built_into = function
  | Build _ | Object _ | Tier_up _ -> `Executable
  | Library _ -> `Library
  | Assembled | Check | Declarations | Typed | Cgt | Ir | Compile_commands _ | Write_backs _ -> `Other

(* No tree is printed when semantics found a problem, since neither tree view
   can show a tree with holes in it. *)
let run_packages build =
  (* The memory layout depends on the target (Cgt.Ref32), which is known
     before anything is lowered. *)
  Cgt.Ref32.target := build.target;
  Cgt.Ref32.library := (match build.view with Library _ -> true | _ -> false);
  let* () = match build.view with Build _ | Library _ | Tier_up _ -> Driver.buildable build.root | _ -> Ok () in
  let root = Option.value build.root ~default:true in
  let* packages =
    Driver.assemble ~root ~imports:build.imports ~stamps:build.stamps build.packages
  in
  match build.view with
  | Assembled ->
      print_string (Tree_graph.render (Tst.Assembly.to_node packages));
      Ok ()
  | Compile_commands output -> Driver.compile_commands ?target:build.target packages output
  | Check | Declarations | Typed | Cgt | Ir | Build _ | Library _ | Object _ | Tier_up _ | Write_backs _ -> (
      let* c = Driver.c_code ?target:build.target packages in
      let* program = Driver.check ~c packages in
      let* kind = if needs_entry build then Driver.root_kind program else Ok Driver.Program in
      let* () = Driver.built_as kind (built_into build.view) in
      let plugin = kind = Driver.Plugin in
      match build.view with
      | Check -> Ok ()
      | Write_backs output -> Driver.write_backs packages program ~output
      | Declarations | Typed ->
          print_string (Tree_graph.render (Tst.to_node ~bodies:(build.view = Typed) program));
          Ok ()
      | _ -> generate ~plugin packages c build program)

(* The only place the binary exits: 0 when the run did what it was asked,
   1 when the compiler refused the program, 2 for a command it cannot run,
   and 3 for a broken invariant, the compiler's own fault. Any other
   exception that escapes a stage also marks a broken invariant. The binary
   ends each line it writes with `\n` on every system, as the programs it
   builds do (docs/design/platforms.md): Windows's text mode would end each
   line with `\r\n`. *)
let () =
  set_binary_mode_out stdout true;
  set_binary_mode_out stderr true;
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
        | Lsp zane ->
            Language_server.Server.run ?zane ();
            Ok ()
        | Rewrite { stamp; input; output } ->
            Driver.rewrite_object ~random:(Random.State.make_self_init ()) ~stamps:[ stamp ]
              ~rewrite:(fun text ->
                if Foreign.Hashes.is text then Foreign.Hashes.rewrite ~stamp text else Rewrite.rewrite ~stamp text)
              ~input ~output
        | Remap { from; to_; input; output } ->
            Driver.rewrite_object ~random:(Random.State.make_self_init ()) ~stamps:[ from; to_ ]
              ~rewrite:(Rewrite.remap ~from ~to_) ~input ~output
        | Bundle_runtime { dir; target; optimize } ->
            Cgt.Ref32.target := Some target;
            Driver.bundle_runtime ~target ~optimize dir
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
        (* With OCAMLRUNPARAM=b, the backtrace of where the exception was raised. *)
        let backtrace = Printexc.get_backtrace () in
        internal
          (if backtrace = "" then Printexc.to_string e else Printexc.to_string e ^ "\n" ^ backtrace)
  in
  exit status
