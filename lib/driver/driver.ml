(* The pipeline as a front end runs it (docs/design/stages.md). Each step
   returns a result whose failure is every problem it found, with the text
   of the files they point into, so a front end prints them all the same
   way. The rules that are about the build rather than about any one stage
   live here too: which package a `--stamp` names, and whether the root
   needs a `main`. So does rewriting an object, fetching's step rather than a
   build's (docs/design/separate-compilation.md C9, C11). *)

module Assembly = Tst.Assembly

type failure = { diagnostics : Diagnostic.t list; sources : Source.Files.t }

let fail ?(sources = []) diagnostics = Error { diagnostics; sources }
let render failure = List.map (Diagnostic.render_in failure.sources) failure.diagnostics

let not_stamp stamp =
  Printf.sprintf
    "`%s` is not a stamp: a version tag of letters, digits, `.`, `_`, `+` and `-`, then `%%`, 16 lowercase hexadecimal digits and `%%`"
    stamp

(* `--stamp NAME=STAMP` gives the one package named NAME its stamp. A stamp
   for a package the build does not have would be dropped silently, and the
   package it was meant for compiled into the root's object rather than
   linked from its own; one for a name two packages have would pick between
   them. A value that is no stamp would name the package's symbols with it,
   while lowering, which recognizes a stamp by its form, took the package
   for unstamped. *)
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

(* The packages of the build, read from their directories, the first the
   root when [root]: a library build has no root (packages.md §6.1). *)
let assemble ?(root = true) ?(imports = []) ?(stamps = []) requests =
  match with_stamps stamps requests with
  | Error _ as e -> e
  | Ok requests -> (
      match Assembly.assemble_requests ~root ~imports requests with
      | Ok packages -> Ok packages
      | Error { Assembly.diagnostics; sources } -> fail ~sources diagnostics)

(* Each package's C (spec ffi.md §2), compiled for [target] by the linked
   clang, with its `c.coda` read and checked (docs/design/ffi.md §1). *)
let c_code ?target packages =
  let dirs = List.map (fun (p : Assembly.package) -> p.Assembly.dir) packages in
  match Codegen.target_cpu ?target () with
  | Error message -> fail [ Diagnostic.about_invocation message ]
  | Ok cpu -> (
      match Foreign.compile_packages ~cc:(Codegen.c_compiler ()) ~cpu ~target dirs with
      | Ok c -> Ok c
      | Error { Foreign.diagnostics; sources } -> fail ~sources diagnostics)

(* Semantics, which reports every problem it finds (docs/design/semantics.md
   D4) and gives no tree when there is one. *)
let check ?(c = []) packages =
  (* [c] is [c_code]'s for these packages, in their order; a caller that
     compiled no C gives none. *)
  let interfaces =
    if c = [] then []
    else List.map2 (fun (p : Assembly.package) (f : Foreign.package) -> (p.Assembly.id, f.Foreign.interface)) packages c
  in
  match Tst.check ~interfaces packages with
  | { Tst.Semantics.diagnostics = []; program } -> Ok program
  | { Tst.Semantics.diagnostics; _ } -> fail ~sources:(Assembly.sources packages) diagnostics

(* A program starts from its root's `main` (packages.md §6.2), so a root
   without it is an error however far the build goes. This is the one check for `main`:
   lowering takes it as given. *)
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
   lowers from every function it declares. *)
(* The sizes of each context's range of frames, from `--fixed-region` and
   `--spawned-fixed-region`; the defaults
   when absent. *)
type regions = { fixed : int option; spawned : int option }

let no_regions = { fixed = None; spawned = None }

(* Every build takes in its stamped dependencies' bodies, which LLVM inlines
   and defines in no object (docs/design/separate-compilation.md C12): an
   unoptimized build's inlining needs them as much as an optimized one's. *)
let lower ?(regions = no_regions) ~root packages program =
  match Cgt.lower ~library:(not root) ~import_bodies:true ?fixed_region:regions.fixed program with
  | Ok cgt -> Ok cgt
  | Error d -> fail ~sources:(Assembly.sources packages) [ d ]

(* The modules of the stamped dependency [p]'s C, [f], that an optimized
   build retains (docs/design/ffi.md F13): its sources' and its glue's whose
   hashes agree with those its release published, [hashes], the glue
   written again from its thunks, [entries], under the labels its
   publisher's glue named them by. None when the release published none
   for it, or none agree. *)
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
      let n = String.length id in
      let label (t : Cgt.Nodes.Foreign.t) =
        labels ^ String.sub t.Cgt.Nodes.Foreign.thunk n (String.length t.Cgt.Nodes.Foreign.thunk - n)
      in
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

(* The rows of each file [paths] names, which `--object` wrote beside a
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

(* The rows of the file [Foreign.Hashes] names for the packages this
   object holds, as [c_modules] made their C, [cs]: each C source's hash,
   from [c], and each glue module's, the package and its labels named as
   its symbols are, and the file relative to the package's directory. *)
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

(* [rows] written beside the object [output], as `STEM.c.hashes`, after
   one an earlier build wrote there is removed: none is written when the
   object holds no C module. *)
let write_hashes ~output rows =
  let path = Filename.remove_extension output ^ ".c.hashes" in
  match
    if Sys.file_exists path then Sys.remove path;
    if rows <> [] then Out_channel.with_open_bin path (fun oc -> output_string oc (Foreign.Hashes.write rows))
  with
  | () -> Ok ()
  | exception Sys_error why -> fail [ Diagnostic.about_invocation ("cannot write the C modules' hashes: " ^ why) ]

(* The C code each package of the build compiles into this object, for
   codegen to link (docs/design/ffi.md F8, F9): its sources' modules, and
   its glue's, made for the thunks [cgt]'s foreign calls go through. A
   stamped dependency's C is in its own objects, and only its archives
   and `system` libraries reach this link. Its globals are renamed
   after the package's symbols: `!` before the name in a library's
   object, which fetching stamps, and nothing in a program's. *)
let c_modules ?target ?(link = []) ?(hashes = []) ~root packages (c : Foreign.package list) (cgt : Cgt.Nodes.Program.t) =
  let module F = Cgt.Nodes.Foreign in
  (* A package's stamp, all of its identity up to its last `%`. The
     packages of the first one's are the project this object holds, and
     an unstamped dependency of a stamped one is compiled in with them;
     only a library's own unstamped packages are named with the `!`
     placeholder (separate-compilation.md C1, C6), as Cgt names them. *)
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
        | F.Scalar Cgt.Nodes.Ty.F32 -> Foreign.Glue.Scalar "float"
        | F.Scalar _ -> Foreign.Glue.Scalar "double"
        | F.Bool -> Foreign.Glue.Bool
        | F.Unit -> Foreign.Glue.Unit
        | F.View | F.Address | F.Value | F.Handle | F.Function -> Foreign.Glue.Same
      in
      let entry ?(label = fun (t : F.t) -> t.F.thunk) (t : F.t) =
        {
          Foreign.Glue.label = global_prefix ^ label t;
          c_function = t.F.c_function;
          params = List.map kind t.F.params;
          result = kind t.F.result;
        }
      in
      (* A package's C apart from its module: the objects its sources
         holding assembly were assembled into, its archives, and its
         `system` libraries, each named by its row. *)
      let apart (f : Foreign.package) =
        let coda = Filename.concat f.Foreign.dir Foreign.Settings.file_name in
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
      (* What the `--link` objects define, by C name (Foreign.Objects.read),
         read once a stamped dependency's archives need it. *)
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
           after the C names those objects define with its prefix, the
           names its own build renamed (docs/design/ffi.md F15). *)
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
              (* Every C name the package's sources define, those
                 assembled apart among them, is the object's, renamed so,
                 declarations too: a retained module reaches a source it
                 calls by the name the dependency's objects define it
                 under. *)
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
      (* The object's function values C can call (docs/design/ffi.md F11):
         its lambdas' C entries, in one module of their own, named by the
         lambdas' symbols. *)
      let module C = Cgt.Nodes.Callback in
      let rec shape (s : C.shape) =
        match s with
        | C.Truth -> Foreign.Glue.Truth
        | C.Nothing -> Foreign.Glue.Nothing
        | C.Scalar Cgt.Nodes.Ty.I32 -> Foreign.Glue.Value "int"
        | C.Scalar Cgt.Nodes.Ty.I64 -> Foreign.Glue.Value "long long"
        | C.Scalar Cgt.Nodes.Ty.F32 -> Foreign.Glue.Value "float"
        | C.Scalar Cgt.Nodes.Ty.F64 -> Foreign.Glue.Value "double"
        | C.Record fs -> Foreign.Glue.Record (List.map (fun (f, n) -> (shape f, n)) fs)
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
            (Foreign.callbacks ~target (List.map entry p))
      in
      match Foreign.combine ((if c = [] then [] else List.map2 one packages c) @ [ callbacks () ]) with
      | Ok cs -> Ok (List.filter_map Fun.id cs)
      | Error { Foreign.diagnostics; sources } -> fail ~sources diagnostics)

(* Stage 5 (docs/design/optimization.md), which only an optimized build
   runs: an unoptimized one skips it. *)
let optimize ~optimize cgt = if optimize then Optimize.run cgt else cgt

(* Codegen's own failures -- an unknown target, a link that failed -- are
   about the build, not about any file of it. *)
let built = function Ok v -> Ok v | Error message -> fail [ Diagnostic.about_invocation message ]

(* The program's module exists only inside [f] (Codegen.with_program),
   emitted for the optimized passes when [version]. *)
let emitted ?target ?pack ?memoize ?c ~version regions cgt f =
  Codegen.with_program ?target ?pack ?memoize ~version ?fixed_region:regions.fixed
    ?spawned_fixed_region:regions.spawned ?c cgt f

let ir ?target ?pack ?memoize ?c ?(regions = no_regions) ~optimize cgt =
  built
    (emitted ?target ?pack ?memoize ?c ~version:optimize regions cgt (fun m ->
         Result.map (fun () -> Codegen.ir m) (Codegen.prepare ?target ~optimize m)))

(* A [tiered] build is tier 0 (docs/design/tiers.md). Every build plans
   what it remembers alike, so it and tier 1 emit the same module. *)
let executable ?target ?pack ?memoize ?c ?(regions = no_regions) ?(tiered = false) ~optimize ~link cgt output =
  let tier = if tiered then Codegen.Tier0 else Codegen.Plain in
  built
    (emitted ?target ?pack ?memoize ?c ~version:(optimize || tiered) regions cgt (fun m ->
         Codegen.executable ?target ~optimize ~tier ~link m output))

(* Tier 1 of a tiered build, from the tree lowering made, without stage 5,
   so it emits the module tier 0 does. *)
let tier_up ?target ?pack ?memoize ?c ?(regions = no_regions) cgt output =
  built (emitted ?target ?pack ?memoize ?c ~version:true regions cgt (fun m -> Codegen.shared_library ?target m output))

let object_file ?target ?pack ?memoize ?c ?(regions = no_regions) ~optimize cgt output =
  built (emitted ?target ?pack ?memoize ?c ~version:optimize regions cgt (fun m -> Codegen.object_file ?target ~optimize m output))

let bundle_runtime ~target ~optimize dir = built (Codegen.bundle_runtime ~target ~optimize dir)

(* A build without a root is checked and built into an object, never into
   an executable. *)
let buildable = function
  | Some false ->
      fail [ Diagnostic.about_invocation "a build without a root is not built into an executable; check it with `--check`" ]
  | _ -> Ok ()

(* The name of a file beside [output] to write it under before it is renamed
   into place, drawn from [random]. *)
let temporary_name random output =
  Filename.concat (Filename.dirname output)
    (Printf.sprintf ".%s.%08x" (Filename.basename output) (Random.State.bits random))

(* How many names [write_replacing] draws before it gives up: each one
   already taken is a file someone else made. *)
let temporary_attempts = 8

(* [contents] written beside [output] and renamed into place, so a failed
   write leaves an existing [output], or the input it may be, as it was. The
   temporary is created exclusively, so a name that already exists is
   another's file: it is left alone and a new name drawn. Any failure to
   create one draws again, since [Sys_error] does not say whether the name
   was taken, and a lookup after the fact misses a dangling symlink or a file
   removed in between. Only a temporary this call created is removed when a
   later step fails. *)
let write_replacing ~random ~output contents =
  let rec attempt drawn =
    let temporary = temporary_name random output in
    let created = ref false in
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
