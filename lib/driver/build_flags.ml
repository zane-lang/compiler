(* The flags of a package build, as `zanec` reads them from its command line
   and as the language server reads them from `zane builds`
   (docs/design/language-server.md): one parser, so the compiler and the
   language server always read the same build from the same flags. *)

(* The flags form no build. *)
exception Usage

let usage () = raise Usage

(* The size in bytes of the range each context reserves for its frames:
   the main context's, from `--fixed-region`, and each spawned call's, from
   `--spawned-fixed-region`. [None] takes the default. *)
type regions = { fixed : int option; spawned : int option }

(* A package build: each `--package` names one package, and the first
   package is the root (docs/design/semantics.md §2).

   A package build prints one of three views: the packages it assembled (the
   default), the declarations with everything passes 1 to 4 resolved about
   them (`--decls`), or the whole typed tree (`--tst`). Past semantics it
   prints the code-generation tree (`--cgt`) or the LLVM module (`--ll`), or
   builds the program into an executable (`--build OUT`,
   docs/design/lowering.md §7) or the root package into an object file
   (`--object OUT`, docs/design/separate-compilation.md C3). A package's
   stamp puts the package's version and identity into its symbols (C6).
   `--import` gives the package that each of a package's import keys names
   (C10). `--link` adds a stamped dependency's object to the link (C7), and
   `--c-hashes` names the file of C module hashes written beside that
   object; an optimized build retains the dependency's C modules whose
   hashes match (docs/design/ffi.md F13, F15). A tiered
   build (docs/design/tiers.md) takes two runs: `--build OUT --tiered` makes
   tier 0, and `--tier-up OUT` makes tier 1, the shared library that tier 0
   loads while it runs. `--check`
   runs semantics and prints only diagnostics, including the C compiler's
   warnings (docs/design/ffi.md F3), so the exit status and the diagnostics
   are the whole result. `--compile-commands OUT` writes the compilation
   database of the C sources of the packages without a stamp, for an
   editor's C language server, and checks nothing (docs/design/ffi.md F2).
   `--write-backs OUT` writes the places that a program's spawned calls
   write back into, and `--program-write-backs FILE` gives a library's build
   the file that a program's `--write-backs` wrote, so the library's object
   is lowered for that program alone (docs/design/lowering.md §9,
   "Snapshots"). *)
type view =
  | Assembled
  | Check
  | Declarations
  | Typed
  | Cgt
  | Ir
  | Build of string
  | Object of string
  | Tier_up of string
  | Compile_commands of string
  | Write_backs of string

(* Whether the build has a root package (packages.md §6.1): `--root` makes
   the first package the root, which has a `main` to start from (§6.2), and
   `--no-root` gives the build no root, so it does not become an executable.
   Without either flag, the first package is the root and `main` is required
   only for lowering. A build without a root lowers from every function it
   declares, with its symbols carrying the `!` placeholder
   (docs/design/separate-compilation.md C5). *)
type t = {
  view : view;
  root : bool option;
  (* The LLVM target triple to compile for; the host's when absent. *)
  target : string option;
  (* Whether `--cgt`, `--ll`, `--build` and `--object` optimize. A program behaves the
     same either way; an unoptimized build is faster to make. *)
  optimize : bool;
  packages : Tst.Assembly.request list;
  (* Stamps given by package name, the objects `--build` links with the
     program, and each package's import keys, each as a triple of the
     importing package, the key and the imported package
     (docs/design/separate-compilation.md C6, C7, C10). *)
  stamps : (string * string) list;
  link : string list;
  c_hashes : string list;
  imports : (string * string * string) list;
  (* The size of each context's range of frames, which `zane` takes from the
     root manifest (memory.md §3.1, dependencies.md §2.1). *)
  regions : regions;
  (* Whether small aggregates cross calls as packed words
     (docs/design/lowering.md §9): a measured experiment, off by default. *)
  pack : bool;
  (* Whether call results are memoized while the program runs (Cgt.Memo):
     on unless `--no-memoize` is given. *)
  memoize : bool;
  (* Whether `--build` makes tier 0 of a tiered build. *)
  tiered : bool;
  (* The places that the program, for which a library's object is built,
     writes back into, as `--write-backs` wrote them. *)
  program_write_backs : string option;
  (* What the runtime's `arguments` gives inside a call marked `comptime`:
     the arguments the build was started with, which `zane` passes on with
     `--build-argument`, in order (docs/design/comptime.md). *)
  build_arguments : string list;
}

(* A package name as lexical.md §3 spells one: camelCase, so a lowercase
   letter and then letters and digits, after a leading `_` when the package
   is private to its project (§4.2, packages.md §4.4). Letters are Unicode
   letters, as in source, so the lexer itself decides which characters
   qualify. *)
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
   its files declare (packages.md §2.2), and `STAMPPATH=DIR` also gives the
   package its stamp; a bare `DIR` names the package after the directory. A
   directory path that itself contains a `=` is still read as a bare `DIR`,
   because the text before its `=` is then not a valid package path. *)
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

(* A build's flags, in any order. Raises [Usage] when they form no build. *)
let parse arguments =
  (* A package build takes its options in any order, each at most once, and at
     least one `--package`. A tree flag or a single source next to these options
     would request two different runs at once. *)
  (* A value never starts with `-`, so a value left out cannot swallow the
     next flag: `--build --package d` is a usage error, not an executable
     named `--package`. *)
  let is_value v = not (String.starts_with ~prefix:"-" v) in
  let rec packages view build = function
    | [] ->
        let view = Option.value view ~default:Assembled in
        if build.packages = [] then usage ()
        else if build.link <> [] && (match view with Build _ -> false | _ -> true) then usage ()
        else if build.c_hashes <> [] && (match view with Build _ | Object _ | Ir | Tier_up _ -> false | _ -> true) then
          usage ()
        (* Tier 0 is made by `--build`, and neither tier takes `--optimize`:
           tier 1 does its own optimization (docs/design/tiers.md). *)
        else if build.tiered && ((match view with Build _ -> false | _ -> true) || build.optimize) then usage ()
        else if (match view with Tier_up _ -> true | _ -> false) && build.optimize then usage ()
        (* A program's write-back places belong to its root; a library built
           for a program has none, and only code from that library reads
           them. *)
        else if (match view with Write_backs _ -> true | _ -> false) && build.root = Some false then usage ()
        else if build.program_write_backs <> None
                && (build.root <> Some false || match view with Cgt | Ir | Object _ -> false | _ -> true)
        then usage ()
        else
          {
            build with
            view;
            (* A Windows host builds for MinGW (Build.host_triple). *)
            target = (match build.target with None when Sys.win32 -> Some Codegen.windows_host_triple | t -> t);
            packages = List.rev build.packages;
            stamps = List.rev build.stamps;
            link = List.rev build.link;
            c_hashes = List.rev build.c_hashes;
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
    | "--compile-commands" :: output :: rest when view = None && is_value output ->
        packages (Some (Compile_commands output)) build rest
    | "--write-backs" :: output :: rest when view = None && is_value output ->
        packages (Some (Write_backs output)) build rest
    | "--program-write-backs" :: file :: rest when build.program_write_backs = None && is_value file ->
        packages view { build with program_write_backs = Some file } rest
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
    | "--c-hashes" :: file :: rest when is_value file ->
        packages view { build with c_hashes = file :: build.c_hashes } rest
    | "--fixed-region" :: bytes :: rest when build.regions.fixed = None ->
        packages view { build with regions = { build.regions with fixed = Some (region_size bytes) } } rest
    | "--spawned-fixed-region" :: bytes :: rest when build.regions.spawned = None ->
        packages view
          { build with regions = { build.regions with spawned = Some (region_size bytes) } }
          rest
    | "--build-argument" :: argument :: rest ->
        packages view { build with build_arguments = build.build_arguments @ [ argument ] } rest
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
      c_hashes = [];
      imports = [];
      regions = { fixed = None; spawned = None };
      pack = false;
      memoize = true;
      build_arguments = [];
      tiered = false;
      program_write_backs = None;
    }
  in
  packages None empty arguments

(* Whether [flag], as the first argument, starts a package build. *)
let starts = function
  | ( "--package" | "--root" | "--no-root" | "--target" | "--optimize" | "--build" | "--object" | "--stamp"
    | "--link" | "--c-hashes" | "--import" | "--build-argument" | "--fixed-region" | "--spawned-fixed-region" | "--pack-aggregates" | "--no-memoize" | "--check"
    | "--compile-commands" | "--write-backs" | "--program-write-backs"
    | "--tiered" | "--tier-up"
    | "--decls" | "--tst" | "--cgt" | "--ll" ) -> true
  | _ -> false
