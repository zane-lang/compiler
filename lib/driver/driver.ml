(* The pipeline as a front end runs it (docs/design/stages.md). Each step
   returns a result whose failure holds every problem the step found, with
   the text of the files the problems point into, so every front end prints
   them the same way. The rules about the build rather than about any one
   stage live here too: which package a `--stamp` names, and whether the
   root needs a `main`. Rewriting an object also lives here, although it is
   a step of fetching rather than of a build
   (docs/design/separate-compilation.md C9, C11). *)

module Assembly = Tst.Assembly

type failure = { diagnostics : Diagnostic.t list; sources : Source.Files.t }

let fail ?(sources = []) diagnostics = Error { diagnostics; sources }
let render failure = List.map (Diagnostic.render_in failure.sources) failure.diagnostics

let not_stamp stamp =
  Printf.sprintf
    "`%s` is not a stamp: a version tag of letters, digits, `.`, `_`, `+` and `-`, then `%%`, 16 lowercase hexadecimal digits and `%%`"
    stamp

(* `--stamp NAME=STAMP` gives its stamp to the single package named NAME,
   and each other case is an error. A stamp for a package the build does
   not have would otherwise be dropped silently, and the intended package
   compiled into the root's object instead of linked from its own object. A
   stamp for a name that two packages share would have to pick one of them.
   A value that is not a stamp would be put into the package's symbols,
   while lowering, which recognizes a stamp by its form, would treat the
   package as unstamped. *)
let with_stamps stamps requests =
  let problems = ref [] in
  let requests =
    List.fold_left
      (fun requests (name, stamp) ->
        let named (r : Assembly.request) =
          r.Assembly.stamp = None && String.equal (Assembly.path_of r) name
        in
        match List.filter named requests with
        | _ when not (Rewrite.is_stamp stamp) ->
            problems := Diagnostic.about_invocation (not_stamp stamp) :: !problems;
            requests
        | [ _ ] -> List.map (fun r -> if named r then { r with Assembly.stamp = Some stamp } else r) requests
        | [] ->
            problems :=
              Diagnostic.about_invocation
                (Printf.sprintf "`--stamp %s=...` names no package given with `--package`" name)
              :: !problems;
            requests
        | _ ->
            problems :=
              Diagnostic.about_invocation
                (Printf.sprintf
                   "`--stamp %s=...` names more than one package; give each its stamp with `--package STAMP%s=DIR`"
                   name name)
              :: !problems;
            requests)
      requests stamps
  in
  match !problems with [] -> Ok requests | problems -> fail (List.rev problems)

(* The packages of the build, read from their directories. When [root] is
   true, the first package is the root; a library build has no root
   (packages.md §6.1). *)
let assemble ?buffers ?(root = true) ?(imports = []) ?(stamps = []) requests =
  match with_stamps stamps requests with
  | Error _ as e -> e
  | Ok requests -> (
      match Assembly.assemble_requests ?buffers ~root ~imports requests with
      | Ok packages -> Ok packages
      | Error { Assembly.diagnostics; sources } -> fail ~sources diagnostics)

(* Prints the warnings the C compiler gave about a package's own C files.
   A warning stops no build. Only a package being worked on gets its
   warnings printed: a dependency's id carries its stamp, and the warnings
   in a dependency's files are for its author to fix. *)
let show_warnings (p : Assembly.package) f =
  if not (String.contains p.Assembly.id '%') then
    let warnings, sources = Foreign.warnings f in
    List.iter (fun d -> prerr_string (Diagnostic.render_in sources d)) warnings

(* Each package's C (spec ffi.md §2), compiled for [target] by the linked
   clang, with its `c.coda` read and checked (docs/design/ffi.md §1). *)
let c_code ?target packages =
  let dirs = List.map (fun (p : Assembly.package) -> p.Assembly.dir) packages in
  match Codegen.target_cpu ?target () with
  | Error message -> fail [ Diagnostic.about_invocation message ]
  | Ok cpu -> (
      match Foreign.compile_packages ~cc:(Codegen.c_compiler ()) ~cpu ~target dirs with
      | Ok c ->
          List.iter2 show_warnings packages c;
          Ok c
      | Error { Foreign.diagnostics; sources } -> fail ~sources diagnostics)

(* A temporary file name beside [output], drawn from [random]: the contents
   are written under this name first and then renamed to [output]. *)
let temporary_name random output =
  Filename.concat (Filename.dirname output)
    (Printf.sprintf ".%s.%08x" (Filename.basename output) (Random.State.bits random))

(* How many temporary names [write_replacing] draws before it gives up. Each
   name that is already taken belongs to a file someone else made. *)
let temporary_attempts = 8

(* Writes [contents] to a temporary file beside [output] and renames it into
   place, so a failed write leaves an existing [output] unchanged, even when
   [output] is also the input. The temporary file is created exclusively, so
   a name that already exists belongs to another file: that file is left
   alone and a new name is drawn. Any failure to create the temporary file
   draws a new name, since [Sys_error] does not show whether the name was
   taken, and a lookup afterwards would miss a dangling symlink or a file
   removed in between. On Windows an exclusive create through a dangling
   symlink creates the symlink's target, so there any existing entry with
   the drawn name, symlinks included, makes the function draw again first.
   When a later step fails, only a temporary file this call created is
   removed. *)
let write_replacing ~random ~output contents =
  let taken name = Sys.win32 && match Unix.lstat name with _ -> true | exception Unix.Unix_error _ -> false in
  let rec attempt drawn =
    let temporary = temporary_name random output in
    let created = ref false in
    if taken temporary then
      if drawn < temporary_attempts then attempt (drawn + 1) else Error (temporary ^ ": the name is taken")
    else
    match
      Out_channel.with_open_gen
        [ Open_wronly; Open_creat; Open_excl; Open_binary ]
        0o666 temporary
        (fun oc ->
          created := true;
          output_string oc contents);
      Sys.rename temporary output
    with
    | () -> Ok ()
    | exception Sys_error message ->
        if !created then begin
          (try Sys.remove temporary with Sys_error _ -> ());
          Error message
        end
        else if drawn < temporary_attempts then attempt (drawn + 1)
        else Error message
  in
  attempt 1

(* Writes to [output] the compilation database of the C sources of the
   [packages] being worked on, which are those without a stamp
   (docs/design/ffi.md F2). *)
let compile_commands ?target packages output =
  let dirs =
    List.filter_map
      (fun (p : Assembly.package) -> if String.contains p.Assembly.id '%' then None else Some p.Assembly.dir)
      packages
  in
  match
    Result.bind
      (Result.map_error (fun message -> { Foreign.diagnostics = [ Diagnostic.about_invocation message ]; sources = [] })
         (Codegen.target_cpu ?target ()))
      (fun cpu -> Foreign.compile_commands ~cc:(Codegen.c_compiler ()) ~cpu ~target dirs)
  with
  | Error { Foreign.diagnostics; sources } -> fail ~sources diagnostics
  | Ok text -> (
      (* Renamed into place, so an editor never reads half a database and a
         failed write keeps the previous database. *)
      match write_replacing ~random:(Random.State.make_self_init ()) ~output text with
      | Ok () -> Ok ()
      | Error message -> fail [ Diagnostic.about_invocation ("the compilation database could not be written: " ^ message) ])

(* Semantics, which reports every problem it finds (docs/design/semantics.md
   D4) and returns no tree when it finds any problem. *)
let check ?(c = []) packages =
  (* [c] is the result of [c_code] for these packages, in the same order; a
     caller that compiled no C passes no [c]. *)
  let interfaces =
    if c = [] then []
    else List.map2 (fun (p : Assembly.package) (f : Foreign.package) -> (p.Assembly.id, f.Foreign.interface)) packages c
  in
  match Tst.check ~interfaces packages with
  | { Tst.Semantics.diagnostics = []; program } -> Ok program
  | { Tst.Semantics.diagnostics; _ } -> fail ~sources:(Assembly.sources packages) diagnostics

(* Semantics as the language server runs it (docs/design/language-server.md):
   the tree, whatever problems it has, with every problem and every name
   the check resolved. [placeholder] is the identifier a completion wrote at
   the cursor. *)
type analysis = {
  program : Tst.Nodes.Program.t;
  diagnostics : Diagnostic.t list;
  index : Tst.Index.t Lazy.t;
}

let analyze ?(c = []) ?placeholder packages =
  let interfaces =
    if c = [] then []
    else List.map2 (fun (p : Assembly.package) (f : Foreign.package) -> (p.Assembly.id, f.Foreign.interface)) packages c
  in
  let { Tst.Semantics.program; diagnostics; index } = Tst.check ~interfaces ~record:true ?placeholder packages in
  { program; diagnostics; index }

(* A program starts from its root's `main` (packages.md §6.2), so a root
   without `main` is an error however far the build goes. This is the only check for
   `main`: lowering assumes it. *)
let require_main (program : Tst.Nodes.Program.t) =
  match program.Tst.Nodes.Program.packages with
  | root :: _ ->
      let declares_main =
        List.exists
          (fun (d : Tst.Nodes.Decl.t) ->
            match d.Tst.Nodes.Decl.node with
            | Tst.Nodes.Decl.Verb { signature; _ } -> signature.Tst.Signature.name = "main"
            | _ -> false)
          root.Tst.Nodes.Package.decls
      in
      if declares_main then Ok ()
      else
        fail
          [
            Diagnostic.about_invocation
              (Printf.sprintf "the root package `%s` declares no `main` to start from"
                 root.Tst.Nodes.Package.name);
          ]
  | [] -> Ok ()

(* Lowering refuses what it cannot handle yet with a diagnostic rather than
   lowering it wrongly (docs/design/lowering.md). A build without a root
   lowers from every function the build declares. *)
(* The sizes of each context's range of frames, from `--fixed-region` and
   `--spawned-fixed-region`; [None] takes the default size. *)
type regions = Build_flags.regions = { fixed : int option; spawned : int option }

let no_regions = { fixed = None; spawned = None }

(* Every build takes in the function bodies of its stamped dependencies.
   LLVM inlines these bodies and defines them in no object
   (docs/design/separate-compilation.md C12), and an unoptimized build's
   inlining needs them as much as an optimized build's does. *)
let lower ?(regions = no_regions) ?(compare_glue = false) ?program_write_backs ~root packages program =
  let read path =
    match In_channel.with_open_bin path In_channel.input_all with
    | exception Sys_error why -> fail [ Diagnostic.about_invocation why ]
    | text -> (
        match Cgt.read_write_backs text with
        | Some ws -> Ok ws
        | None -> fail [ Diagnostic.about_invocation (Printf.sprintf "`%s` is not a file of a program's write-backs" path) ])
  in
  let ( let* ) = Result.bind in
  let* program_write_backs =
    match program_write_backs with Some path -> Result.map Option.some (read path) | None -> Ok None
  in
  match
    Cgt.lower ~library:(not root) ~import_bodies:true ~foreign_roots:compare_glue ?fixed_region:regions.fixed
      ?program_write_backs program
  with
  | Ok cgt -> Ok cgt
  | Error d -> fail ~sources:(Assembly.sources packages) [ d ]

(* The file is written whole or not at all, since `zane` keys a
   dependency's object on its bytes. *)
let write_backs packages program ~output =
  match Cgt.write_backs program with
  | Error d -> fail ~sources:(Assembly.sources packages) [ d ]
  | Ok text -> (
      let random = Random.State.make_self_init () in
      match write_replacing ~random ~output text with
      | Ok () -> Ok ()
      | Error why -> fail [ Diagnostic.about_invocation ("cannot write the program's write-backs: " ^ why) ])

(* The modules of [f], the C of the stamped dependency [p], that an
   optimized build retains (docs/design/ffi.md F13). These are the modules of
   its C sources and of its glue whose hashes match the hashes its release
   published, [hashes]. The glue is written again from the dependency's
   thunks, [entries], under the labels that the publisher's glue used.
   [None] when the release published no hashes for [p], or when no hash
   matches. *)
let retained_c ~hashes ~(entry : ?label:(Cgt.Nodes.Foreign.t -> string) -> Cgt.Nodes.Foreign.t -> Foreign.Glue.entry) (p : Assembly.package) (f : Foreign.package) (entries : Cgt.Nodes.Foreign.t list) =
  let module H = Foreign.Hashes in
  let id = p.Assembly.id in
  let rows = List.filter (fun (r : H.row) -> r.H.package = id) hashes in
  let agreed kind key = List.exists (fun (r : H.row) -> r.H.kind = kind && r.H.hash = key) rows in
  let own (t : Cgt.Nodes.Foreign.t) = String.starts_with ~prefix:(id ^ "$") t.Cgt.Nodes.Foreign.thunk in
  match rows with
  | [] -> Ok None
  | _ when entries = [] || not (List.for_all own entries) -> Ok None
  | first :: _ ->
      let labels = first.H.labels in
      (* A thunk's symbol names the package in several places: before the
         verb, and in each of the package's own types that the verb names,
         as in `this lib$State`. *)
      let label (t : Cgt.Nodes.Foreign.t) = Rewrite.respell ~from:(id ^ "$") ~into:(labels ^ "$") t.Cgt.Nodes.Foreign.thunk in
      Result.map
        (fun glue ->
          let glue =
            List.filter_map
              (fun (header, (s : Foreign.Compile.source)) ->
                if agreed H.Glue s.key then Some { Codegen.key = s.key; bitcode = s.bitcode; files = [ header ] } else None)
              glue
          in
          let sources =
            List.filter_map
              (fun (s : Foreign.Compile.source) ->
                if agreed H.Source s.key then Some { Codegen.key = s.key; bitcode = s.bitcode; files = s.includes }
                else None)
              f.Foreign.sources
          in
          if glue = [] then None else Some (labels, sources, glue))
        (Foreign.glue f (List.map (fun t -> entry ~label t) entries))

(* The rows of each file in [paths]. `--object` wrote these files beside a
   dependency's object (Foreign.Hashes). *)
let read_hashes paths =
  let one path =
    match In_channel.with_open_bin path In_channel.input_all with
    | exception Sys_error why -> Error why
    | text -> Result.map_error (Printf.sprintf "`%s` is not a file of C module hashes: %s" path) (Foreign.Hashes.read text)
  in
  match Foreign.combine (List.map (fun p -> Result.map_error (fun m -> { Foreign.diagnostics = [ Diagnostic.about_invocation m ]; sources = [] }) (one p)) paths) with
  | Ok rows -> Ok (List.concat rows)
  | Error { Foreign.diagnostics; sources } -> fail ~sources diagnostics

(* The rows of the [Foreign.Hashes] file for the packages this object holds,
   whose C [c_modules] made as [cs]. There is a row for the hash of each C
   source, taken from [c], and for the hash of each glue module. Each row
   names the package and its labels as the package's symbols spell them, and
   the file relative to the package's directory. *)
let hashes_of packages (c : Foreign.package list) (cs : Codegen.c_package list) =
  let module H = Foreign.Hashes in
  let relative dir file =
    let dir = if Filename.is_relative dir then Filename.concat (Sys.getcwd ()) dir else dir in
    let dir = Foreign.Compile.real dir ^ Filename.dir_sep in
    let file = Foreign.Compile.real file in
    if String.starts_with ~prefix:dir file then String.sub file (String.length dir) (String.length file - String.length dir)
    else Filename.basename file
  in
  let rows (p : Assembly.package) (f : Foreign.package) =
    let own = p.Assembly.id ^ "$%c$" in
    let mine (k : Codegen.c_package) =
      k.Codegen.labels = None && (k.Codegen.prefix = own || k.Codegen.prefix = "!" ^ own)
    in
    match List.filter mine cs with
    | [] -> []
    | k :: _ as ks ->
        let name = String.sub k.Codegen.prefix 0 (String.length k.Codegen.prefix - 4) in
        let row kind file hash = { H.package = name; labels = name; kind; file = relative p.Assembly.dir file; hash } in
        let glue =
          List.concat_map
            (fun (k : Codegen.c_package) ->
              List.filter_map
                (fun (m : Codegen.c_module) ->
                  match m.Codegen.files with [ header ] -> Some (row H.Glue header m.Codegen.key) | _ -> None)
                k.Codegen.glue)
            ks
        in
        let sources = if k.Codegen.sources = [] then [] else f.Foreign.sources in
        List.map (fun (s : Foreign.Compile.source) -> row H.Source s.path s.key) sources @ glue
  in
  if c = [] then [] else List.concat (List.map2 rows packages c)

(* Writes [rows] beside the object [output], as `STEM.c.hashes`, after
   removing any such file an earlier build wrote there. No file is written
   when the object holds no C module. *)
let write_hashes ~output rows =
  let path = Filename.remove_extension output ^ ".c.hashes" in
  match
    if Sys.file_exists path then Sys.remove path;
    if rows <> [] then Out_channel.with_open_bin path (fun oc -> output_string oc (Foreign.Hashes.write rows))
  with
  | () -> Ok ()
  | exception Sys_error why -> fail [ Diagnostic.about_invocation ("cannot write the C modules' hashes: " ^ why) ]

(* The C code each package of the build compiles into this object, for
   codegen to link (docs/design/ffi.md F8, F9): the modules of the package's
   C sources, and of its glue, made for the thunks that [cgt]'s foreign
   calls go through. A stamped dependency's C is in its own objects, and
   only its archives and `system` libraries reach this link. The C globals
   are renamed after the package's symbols: with `!` before the package
   name in a library's object, which fetching stamps, and with no prefix in
   a program's object. *)
let c_modules ?target ?(link = []) ?(hashes = []) ~root packages (c : Foreign.package list) (cgt : Cgt.Nodes.Program.t) =
  let module F = Cgt.Nodes.Foreign in
  (* A package's stamp: its id up to and including the last `%`. The
     packages with the first package's stamp are the project this object
     holds, and an unstamped dependency of a stamped package is compiled in
     with them. Only a library's own unstamped packages are named with the
     `!` placeholder (separate-compilation.md C1, C6), as Cgt names them. *)
  let stamp id = match String.rindex_opt id '%' with Some i -> String.sub id 0 (i + 1) | None -> "" in
  let project = match packages with (r : Assembly.package) :: _ -> stamp r.Assembly.id | [] -> "" in
  let prefix id = (if (not root) && project = "" && stamp id = "" then "!" else "") ^ id ^ "$%c$" in
  (* Each of [names] that starts with [own], without it. *)
  let after own names =
    let n = String.length own in
    List.filter_map
      (fun name -> if String.starts_with ~prefix:own name then Some (String.sub name n (String.length name - n)) else None)
      names
  in
  match Codegen.global_prefix ?target () with
  | Error message -> fail [ Diagnostic.about_invocation message ]
  | Ok global_prefix -> (
      let kind = function
        | F.Scalar Cgt.Nodes.Ty.I32 -> Foreign.Glue.Scalar "int32_t"
        | F.Scalar Cgt.Nodes.Ty.I64 -> Foreign.Glue.Scalar "int64_t"
        | F.Scalar Cgt.Nodes.Ty.I8 -> Foreign.Glue.Scalar "uint8_t"
        | F.Scalar Cgt.Nodes.Ty.F32 -> Foreign.Glue.Scalar "float"
        | F.Scalar Cgt.Nodes.Ty.F64 -> Foreign.Glue.Scalar "double"
        | F.Scalar _ -> Diagnostic.bug "codegen: a foreign verb passes C a scalar of a type it does not take"
        | F.Bool -> Foreign.Glue.Bool
        | F.Unit -> Foreign.Glue.Unit
        | F.Terminated -> Foreign.Glue.Terminated
        | F.View | F.Address | F.Value | F.Handle | F.Function -> Foreign.Glue.Same
      in
      let entry ?(label = fun (t : F.t) -> t.F.thunk) (t : F.t) =
        {
          Foreign.Glue.label = global_prefix ^ label t;
          c_function = t.F.c_function;
          params = List.map kind t.F.params;
          (* Only a string result is returned as a view. *)
          result = (match t.F.result with F.View -> Foreign.Glue.Text | r -> kind r);
        }
      in
      (* A package's C outside its module: the objects assembled from its
         sources that hold assembly, its archives, and its `system`
         libraries, each library named by its row in `c.coda`. *)
      let apart (f : Foreign.package) =
        let coda = Source.Files.in_directory f.Foreign.dir Foreign.Settings.file_name in
        ( List.map
            (fun (a : Foreign.assembled) ->
              ({ Codegen.key = a.source.key; bitcode = a.source.bitcode; files = a.source.includes }, a.object_))
            f.Foreign.assembled,
          List.map
            (fun (a : Foreign.archive) -> { Codegen.digest = a.digest; members = a.members })
            f.Foreign.archives,
          List.map
            (fun (number, name) ->
              { Codegen.name; row = Printf.sprintf "row %d of `%s`" number coda })
            (Foreign.libraries f) )
      in
      (* The C names that the `--link` objects define (Foreign.Objects.read),
         read the first time a stamped dependency's archives need them. *)
      let published =
        let rec all = function
          | [] -> Ok []
          | Ok x :: rest -> Result.map (List.cons x) (all rest)
          | (Error _ as e) :: _ -> e
        in
        lazy
          (all
             (List.map
                (fun path ->
                  match In_channel.with_open_bin path In_channel.input_all with
                  | exception Sys_error why -> Error why
                  | bytes ->
                      Result.map
                        (fun (c : Foreign.Objects.contents) -> c.Foreign.Objects.defined)
                        (Foreign.Objects.read bytes)
                      |> Result.map_error (Printf.sprintf "`%s` is not an object file: %s" path))
                link))
      in
      let one (p : Assembly.package) (f : Foreign.package) =
        let entries = List.filter (fun (t : F.t) -> t.F.package = p.Assembly.id) cgt.Cgt.Nodes.Program.foreign in
        let objects, archives, libraries = apart f in
        let package ?(sources = []) ?(glue = []) ?(thunks = []) ?(objects = []) ?(archives = []) ?(defined = []) ?labels
            () =
          { Codegen.prefix = prefix p.Assembly.id; sources; glue; thunks; objects; archives; defined; libraries; labels }
        in
        (* A stamped dependency's C is in its objects, which link with its
           `system` libraries and its archives. The archives are renamed
           after the C names that those objects define with the package's
           prefix, which are the names the dependency's own build renamed
           (docs/design/ffi.md F15). *)
        let elsewhere = stamp p.Assembly.id <> "" && stamp p.Assembly.id <> project in
        let ( let* ) = Result.bind in
        if elsewhere then
          let* defined =
            if archives = [] then Ok []
            else
              match Lazy.force published with
              | Error message ->
                  Error { Foreign.Compile.diagnostics = [ Diagnostic.about_invocation message ]; sources = [] }
              | Ok names -> Ok (Foreign.object_defined f @ after (prefix p.Assembly.id) (List.concat names))
          in
          let* retained = retained_c ~hashes ~entry p f entries in
          match retained with
          | Some (labels, sources, glue) ->
              (* Every C name that the package's sources define, including
                 the sources assembled separately, belongs to the object and
                 is renamed the same way, declarations included: a retained
                 module calls into a source by the name the dependency's
                 objects define it under. *)
              let defined =
                (if archives = [] then Foreign.object_defined f else defined)
                @ List.concat_map (fun (s : Foreign.Compile.source) -> fst (Foreign.Clang.definitions s.bitcode)) f.Foreign.sources
              in
              Ok
                (Some
                   (package ~sources ~glue ~thunks:(List.map (fun (t : F.t) -> t.F.thunk) entries) ~archives ~defined
                      ~labels ()))
          | None when archives <> [] -> Ok (Some (package ~archives ~defined ()))
          | None -> Ok (if libraries = [] then None else Some (package ()))
        else if f.Foreign.sources = [] && objects = [] && archives = [] && entries = [] then
          Ok (if libraries = [] then None else Some (package ()))
        else
          Result.map
            (fun glue ->
              let c_module files (s : Foreign.Compile.source) = { Codegen.key = s.key; bitcode = s.bitcode; files } in
              Some
                (package
                   ~sources:(List.map (fun (s : Foreign.Compile.source) -> c_module s.includes s) f.Foreign.sources)
                   ~glue:(List.map (fun (header, s) -> c_module [ header ] s) glue)
                   ~thunks:(List.map (fun (t : F.t) -> t.F.thunk) entries)
                   ~objects ~archives ~defined:(Foreign.object_defined f) ()))
            (Foreign.glue f (List.map entry entries))
      in
      (* The object's function values that C can call (docs/design/ffi.md
         F11): the C entries of its lambdas, in one module of their own,
         named after the lambdas' symbols. *)
      let module C = Cgt.Nodes.Callback in
      let rec shape (s : C.shape) =
        match s with
        | C.Truth -> Foreign.Glue.Truth
        | C.Nothing -> Foreign.Glue.Nothing
        | C.Scalar Cgt.Nodes.Ty.I8 -> Foreign.Glue.Value "unsigned char"
        | C.Scalar Cgt.Nodes.Ty.I32 -> Foreign.Glue.Value "int"
        | C.Scalar Cgt.Nodes.Ty.I64 -> Foreign.Glue.Value "long long"
        | C.Scalar Cgt.Nodes.Ty.F32 -> Foreign.Glue.Value "float"
        | C.Scalar Cgt.Nodes.Ty.F64 -> Foreign.Glue.Value "double"
        | C.Record fs -> Foreign.Glue.Record (List.map (fun (f, n) -> (shape f, n)) fs)
        (* With frame references, a list's room counts its elements, and
           frame references also narrow the list's count and room to 32
           bits (Codegen.List_handle). *)
        | C.View { text = true; _ } -> Foreign.Glue.View { unit = 1; narrow = false }
        | C.View { stride; _ } ->
            if Cgt.Ref32.frames () then Foreign.Glue.View { unit = 1; narrow = true }
            else Foreign.Glue.View { unit = stride; narrow = false }
        | C.Elements _ | C.Object _ -> Foreign.Glue.Pointer
        | C.Scalar _ -> Diagnostic.bug "codegen: a function value C calls with a type it does not take"
      in
      let callbacks () =
        let p = List.filter (fun (c : C.t) -> c.C.here) cgt.Cgt.Nodes.Program.callbacks in
        if p = [] then Ok None
        else
          let entry (c : C.t) =
            {
              Foreign.Glue.label = global_prefix ^ c.C.entry;
              adapter = global_prefix ^ C.adapter c.C.symbol;
              params = List.map shape c.C.takes;
              result = shape c.C.gives;
            }
          in
          Result.map
            (fun (s : Foreign.Compile.source) ->
              let id = match packages with (r : Assembly.package) :: _ -> r.Assembly.id | [] -> "" in
              Some
                {
                  Codegen.prefix = prefix id;
                  sources = [];
                  glue = [ { Codegen.key = s.key; bitcode = s.bitcode; files = [] } ];
                  thunks = List.map (fun (c : C.t) -> c.C.entry) p;
                  objects = [];
                  archives = [];
                  defined = [];
                  libraries = [];
                  labels = None;
                })
            (Result.bind
               (Result.map_error
                  (fun message -> { Foreign.diagnostics = [ Diagnostic.about_invocation message ]; sources = [] })
                  (Codegen.target_cpu ?target ()))
               (fun cpu -> Foreign.callbacks ~cpu ~target (List.map entry p)))
      in
      match Foreign.combine ((if c = [] then [] else List.map2 one packages c) @ [ callbacks () ]) with
      | Ok cs -> Ok (List.filter_map Fun.id cs)
      | Error { Foreign.diagnostics; sources } -> fail ~sources diagnostics)

(* The handling of the clock readings that a tiered build's `comptime`
   calls make (docs/design/tiers.md T12): tier 0 records them in a file,
   and tier 1 replays that file. *)
type readings = Record of string | Replay of string

(* [readings] in the file, whole: tier 0 writes it beside its name and
   renames it into place, so tier 1 never reads half of it. *)
let write_readings file readings =
  let partial = file ^ ".partial" in
  match
    Out_channel.with_open_text partial (fun oc ->
        List.iter (fun r -> Printf.fprintf oc "%Ld\n" r) readings);
    Sys.rename partial file
  with
  | () -> Ok ()
  | exception Sys_error message -> Error (Printf.sprintf "cannot write the clock readings to %s: %s" file message)

(* The readings in [file], in order, given one at a time. Tier 1 is built
   while tier 0 is, so the first reading waits until tier 0 has put the
   file in place; a program whose `comptime` calls never read the clock
   never waits. A line that is not a reading ends them. *)
let replayed file =
  let left = ref None in
  let rec parsed = function
    | line :: rest -> (match Int64.of_string_opt line with Some r -> r :: parsed rest | None -> [])
    | [] -> []
  in
  let rec arrived () =
    if Sys.file_exists file then parsed (In_channel.with_open_text file In_channel.input_lines)
    else begin
      Unix.sleepf 0.01;
      arrived ()
    end
  in
  fun () ->
    let readings = match !left with Some r -> r | None -> arrived () in
    match readings with
    | [] ->
        left := Some [];
        None
    | r :: rest ->
        left := Some rest;
        Some r

(* The calls marked `comptime` (docs/design/comptime.md), which every build
   evaluates. Tier 0 writes its readings even when a call fails, so tier 1
   reaches the same failure instead of waiting. *)
let comptime ?target ?(c = []) ?readings ~arguments packages cgt =
  let kept = ref [] in
  let clock =
    match readings with
    | None -> Optimize.Live
    | Some (Record _) -> Optimize.Recorded kept
    | Some (Replay file) -> Optimize.Replayed (replayed file)
  in
  let evaluated modules =
    match Optimize.comptime ~c:modules ~clock ~arguments cgt with
    | Ok cgt -> Ok cgt
    | Error ds -> fail ~sources:(Assembly.sources packages) ds
  in
  let result =
    if cgt.Cgt.Nodes.Program.comptime = [] then Ok cgt
    else if c = [] then evaluated []
    else
      match Codegen.with_c_modules ?target c evaluated with
      | Ok result -> result
      | Error message -> fail [ Diagnostic.about_invocation message ]
  in
  match readings with
  | Some (Record file) -> (
      match write_readings file (List.rev !kept) with
      | Ok () -> result
      | Error message -> fail [ Diagnostic.about_invocation message ])
  | None | Some (Replay _) -> result

(* Stage 5 (docs/design/optimization.md), which only an optimized build
   runs. A call into C is folded by running [c], the packages' C code
   (docs/design/ffi.md F16). *)
let optimize ?target ?(c = []) ~optimize cgt =
  if not optimize then Ok cgt
  else if c = [] then Ok (Optimize.run cgt)
  else
    match Codegen.with_c_modules ?target c (fun modules -> Optimize.run ~c:modules cgt) with
    | Ok cgt -> Ok cgt
    | Error message -> fail [ Diagnostic.about_invocation message ]

(* Codegen's own failures -- an unknown target, a link that failed -- are
   about the build, not about any of its files. *)
let built = function Ok v -> Ok v | Error message -> fail [ Diagnostic.about_invocation message ]

(* The program's LLVM module exists only inside [f] (Codegen.with_program).
   When [version] is true, the module is emitted for the optimized passes. *)
let emitted ?target ?pack ?memoize ?c ?tiered ~version regions cgt f =
  Codegen.with_program ?target ?pack ?memoize ~version ?tiered ?fixed_region:regions.fixed
    ?spawned_fixed_region:regions.spawned ?c cgt f

let ir ?target ?pack ?memoize ?c ?(regions = no_regions) ~optimize cgt =
  built
    (emitted ?target ?pack ?memoize ?c ~version:optimize regions cgt (fun m ->
         Result.map (fun () -> Codegen.ir m) (Codegen.prepare ?target ~optimize m)))

(* A [tiered] build is tier 0 (docs/design/tiers.md). Every build plans its
   memoization the same way, so tier 0 and tier 1 emit the same module. *)
let executable ?target ?pack ?memoize ?c ?(regions = no_regions) ?(tiered = false) ~optimize ~link cgt output =
  let tier = if tiered then Codegen.Tier0 else Codegen.Plain in
  built
    (emitted ?target ?pack ?memoize ?c ~tiered ~version:(optimize || tiered) regions cgt (fun m ->
         Codegen.executable ?target ~optimize ~tier ~link m output))

(* Tier 1 of a tiered build, built from the tree that lowering made, without
   stage 5, so tier 1 emits the same module as tier 0. *)
let tier_up ?target ?pack ?memoize ?c ?(regions = no_regions) cgt output =
  built (emitted ?target ?pack ?memoize ?c ~tiered:true ~version:true regions cgt (fun m -> Codegen.shared_library ?target m output))

let object_file ?target ?pack ?memoize ?c ?(regions = no_regions) ~optimize cgt output =
  built (emitted ?target ?pack ?memoize ?c ~version:optimize regions cgt (fun m -> Codegen.object_file ?target ~optimize m output))

let bundle_runtime ~target ~optimize dir = built (Codegen.bundle_runtime ~target ~optimize dir)

(* A build without a root is checked and built into an object, never into
   an executable. *)
let buildable = function
  | Some false ->
      fail [ Diagnostic.about_invocation "a build without a root is not built into an executable; check it with `--check`" ]
  | _ -> Ok ()

(* The output is written only once the whole object has been rewritten, so a
   malformed input leaves nothing behind. *)
let rewrite_object ~random ~stamps ~rewrite ~input ~output =
  let ( let* ) = Result.bind in
  let rewritten =
    let* () =
      match List.find_opt (fun stamp -> not (Rewrite.is_stamp stamp)) stamps with
      | Some stamp -> Error (not_stamp stamp)
      | None -> Ok ()
    in
    let* () =
      match stamps with
      | [ from; to_ ] when not (Rewrite.same_package from to_) ->
          Error
            (Printf.sprintf
               "`%s` and `%s` are versions of two packages, since their identity hashes differ; \
                remapping moves references between versions of one package"
               from to_)
      | _ -> Ok ()
    in
    let* contents =
      match In_channel.with_open_bin input In_channel.input_all with
      | exception Sys_error message -> Error message
      | contents -> Ok contents
    in
    let* rewritten, _ =
      Result.map_error (fun message -> input ^ ": " ^ message) (rewrite contents)
    in
    Result.map_error
      (fun message -> Printf.sprintf "cannot write `%s`: %s" output message)
      (write_replacing ~random ~output rewritten)
  in
  match rewritten with
  | Ok () -> Ok ()
  | Error message -> fail [ Diagnostic.about_invocation message ]

module Build_flags = Build_flags
