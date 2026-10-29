(* The C interface's front half (docs/design/ffi.md §1): each package's
   `c.coda`, and its C sources compiled for the build's target by the
   linked clang. *)

module Settings = Settings
module Probe = Probe
module Clang = Clang
module Compile = Compile
module Interface = C_interface
module Glue = Glue
module Objects = Objects

(* A C source whose module holds assembly, emitted as an object of its own
   (docs/design/ffi.md F9): its module, the object, and what the object
   holds. *)
type assembled = { source : Compile.source; object_ : string; contents : Objects.contents }

(* An `archive` row's static library (docs/design/ffi.md F4): its path, a
   hash of its bytes, its members, each its name and its bytes, and what
   they hold between them. *)
type archive = {
  path : string;
  digest : string;
  members : (string * string) list;
  held : Objects.contents;
}

(* What a package's C build is: the rows of its `c.coda` that apply to the
   build, its interface headers and what they declare, its C sources
   compiled, those holding assembly apart, and its archives read. *)
type package = {
  dir : string;
  rows : Settings.row list;
  headers : string list;
  interface : C_interface.t;
  sources : Compile.source list;
  assembled : assembled list;
  archives : archive list;
  (* What each interface header declares, in the order they are read, and
     what compiling the package's glue needs: the flags its sources were
     compiled with, the directories they map, and the cache. *)
  tables : (string * C_interface.t) list;
  flags : string list;
  maps : (string * string) list;
  cache : string option;
}

type failure = Compile.failure = { diagnostics : Diagnostic.t list; sources : Source.Files.t }

(* The triple a build for [target] compiles C for, as LLVM normalizes it:
   the host's when [None]. *)
let triple target = Clang.normalize (match target with Some t -> t | None -> Clang.host_triple ())

let rec remove path =
  if Sys.is_directory path then begin
    Array.iter (fun e -> remove (Filename.concat path e)) (Sys.readdir path);
    Sys.rmdir path
  end
  else Sys.remove path

(* A directory of its own for a build's probe and, without a cache, its
   headers, which compiling the glue reads after the sources are compiled:
   removed when the process exits. *)
let work_dir () =
  let dir = Filename.temp_dir "zane-c-" "" in
  at_exit (fun () -> try remove dir with Sys_error _ -> ());
  dir

let combine results =
  let failures = List.filter_map (function Error f -> Some f | Ok _ -> None) results in
  if failures = [] then Ok (List.filter_map (function Ok v -> Some v | Error _ -> None) results)
  else
    Error
      {
        diagnostics = List.concat_map (fun (f : failure) -> f.diagnostics) failures;
        sources = List.concat_map (fun (f : failure) -> f.sources) failures;
      }

(* Both results as one: the second's value, or every problem either had. *)
let both a b =
  match (a, b) with
  | Ok a, Ok b -> Ok (a, b)
  | Error e, Ok _ | Ok _, Error e -> Error e
  | Error a, Error b -> Error { diagnostics = a.diagnostics @ b.diagnostics; sources = a.sources @ b.sources }

(* [dir]'s `c.coda`, the rows that apply to a build for [triple]. *)
let read_settings ~triple dir =
  let coda = Filename.concat dir Settings.file_name in
  let sources () = match Cache.read coda with Some text -> [ (coda, text) ] | None -> [] in
  Settings.read ~triple dir
  |> Result.map_error (fun diagnostics -> { diagnostics; sources = sources () })
  |> Result.map (fun rows -> (dir, rows))

let with_sources (dir, rows) =
  Settings.sources dir rows
  |> Result.map_error (fun diagnostics -> { diagnostics; sources = [] })
  |> Result.map (fun sources -> (dir, rows, sources))

(* A section the linker gathers into a range that C reaches through the
   `__start_` and `__stop_` symbols named after it: one whose name is a C
   identifier (spec ffi.md §2.5). Its name is not renamed, so two versions
   of a package would share it, and a module that places a global in one
   is refused (docs/design/ffi.md F9). [file] is what the diagnostic
   names: the source, or the interface header a glue file includes. *)
let linker_sets ~file (source : Compile.source) =
  match
    List.filter (fun (_, section) -> Settings.is_identifier section) (Clang.sections source.Compile.bitcode)
  with
  | [] -> Ok source
  | placed ->
      Error
        {
          diagnostics =
            List.map
              (fun (global, section) ->
                Diagnostic.in_file file
                  (Printf.sprintf
                     "`%s` is placed in the section `%s`, a linker set, which the package would share with every other version of it, since a section is gathered by its name (ffi.md §2.5)"
                     global section))
              placed;
          sources = [];
        }

(* A glue module holding assembly, which can name a symbol no global value
   stands for (docs/design/ffi.md F9). The glue's module is linked into the
   package's, which is renamed by its global values, so assembly that
   reaches it through an interface header would keep a name another
   version of the package shares. *)
let assembly ~header (source : Compile.source) =
  if Clang.has_assembly source.Compile.bitcode then
    Error
      {
        diagnostics =
          [
            Diagnostic.in_file header
              "this interface header holds assembly, which the glue that includes it cannot rename, \
               since the glue is linked into the package's C module; move the assembly into a C \
               source, which is assembled as an object of its own (docs/design/ffi.md F9)";
          ];
        sources = [];
      }
  else Ok source

(* The sections of an object whose names are linker sets, each refused as
   a module's are ([linker_sets]): [what] says what places something in
   it, and [file] is the file the diagnostic names. *)
let object_linker_sets ~file ~what (contents : Objects.contents) =
  match List.sort_uniq compare (List.filter Settings.is_identifier contents.Objects.sections) with
  | [] -> Ok contents
  | placed ->
      Error
        {
          diagnostics =
            List.map
              (fun section ->
                Diagnostic.in_file file
                  (Printf.sprintf
                     "%s places something in the section `%s`, a linker set, which the package would share with every other version of it, since a section is gathered by its name (ffi.md §2.5)"
                     what section))
              placed;
          sources = [];
        }

let refused file message = Error { diagnostics = [ Diagnostic.in_file file message ]; sources = [] }

(* [source], whose module holds assembly, emitted for [triple] and [cpu] as
   an object of its own and read (docs/design/ffi.md F9), from [cache]'s
   when it holds it. *)
let assemble ?cache ~triple ~cpu (source : Compile.source) =
  let ( let* ) = Result.bind in
  let file = source.Compile.path in
  let* object_ =
    match Objects.emit ?cache ~triple ~cpu ~key:source.Compile.key source.Compile.bitcode with
    | Ok object_ -> Ok object_
    | Error why -> refused file ("this C holds assembly, which could not be assembled: " ^ why)
  in
  let* contents =
    match Objects.read object_ with
    | Ok contents -> Ok contents
    | Error why ->
        Diagnostic.bug (Printf.sprintf "the object %s was assembled into does not read back: %s" file why)
  in
  let* contents = object_linker_sets ~file ~what:"the object this C is assembled into" contents in
  Ok { source; object_; contents }

(* The static library an `archive` row of [dir]'s names, read member by
   member, each member's sections held to the linker-set test. *)
let archive dir (row : Settings.row) =
  let ( let* ) = Result.bind in
  let coda = Filename.concat dir Settings.file_name and path = Filename.concat dir row.value in
  let at_row message = Error { diagnostics = [ Settings.problem coda row.number message ]; sources = [] } in
  let* bytes =
    match Cache.read path with
    | Some bytes -> Ok bytes
    | None -> at_row (Printf.sprintf "`%s` cannot be read" row.value)
  in
  let* members =
    match Objects.members bytes with
    | Ok members -> Ok members
    | Error why -> at_row (Printf.sprintf "`%s` is not a static library: %s" row.value why)
  in
  let member (name, member_bytes) =
    match Objects.read member_bytes with
    | Error why -> refused path (Printf.sprintf "the member `%s` is not an object file: %s" name why)
    | Ok contents ->
        object_linker_sets ~file:path ~what:(Printf.sprintf "the member `%s`" name) contents
  in
  let* held = combine (List.map member members) in
  let union f = List.concat_map f held in
  Ok
    {
      path;
      digest = Digest.to_hex (Digest.string bytes);
      members;
      held =
        {
          Objects.defined = union (fun c -> c.Objects.defined);
          data = union (fun c -> c.Objects.data);
          sections = union (fun c -> c.Objects.sections);
        };
    }

(* One package's C: its interface headers read, its sources compiled, with
   the [fixed] flags and its own, those holding assembly emitted as objects
   for [triple] and [cpu], and its archives read. *)
let compile_package ?cache ~fixed ~headers ~triple ~cpu (dir, rows, sources) =
  let maps = Compile.prefix_maps ~dir ~headers in
  let flags = fixed @ Compile.map_flags maps @ Compile.package_flags dir rows in
  let interface_headers = Settings.interface_headers dir in
  let tables =
    combine
      (List.map
         (fun h -> Result.map (fun t -> (h, t)) (Compile.interface flags (Filename.concat dir h)))
         interface_headers)
  in
  (* A source holding assembly is never linked into the package's module:
     it is an object of its own. *)
  let compiled_source s =
    let path = Filename.concat dir s in
    let ( let* ) = Result.bind in
    let* source = Compile.compile_source ?cache ~maps flags path in
    let* source = linker_sets ~file:path source in
    if Clang.has_assembly source.Compile.bitcode then
      Result.map Either.right (assemble ?cache ~triple ~cpu source)
    else Ok (Either.Left source)
  in
  let compiled = Result.map (List.partition_map Fun.id) (combine (List.map compiled_source sources)) in
  let archive_row (row : Settings.row) = if row.setting = Settings.Archive then Some (archive dir row) else None in
  let archives = combine (List.filter_map archive_row rows) in
  let defined (sources : Compile.source list) assembled archives =
    List.concat_map (fun (s : Compile.source) -> Clang.defined_variables s.bitcode) sources
    @ List.concat_map (fun a -> a.contents.Objects.data) assembled
    @ List.concat_map (fun a -> a.held.Objects.data) archives
  in
  both tables (both compiled archives)
  |> Result.map (fun (tables, ((sources, assembled), archives)) ->
         let interface = List.fold_left C_interface.merge C_interface.empty (List.map snd tables) in
         {
           dir;
           rows;
           headers = interface_headers;
           interface = { interface with defined = defined sources assembled archives };
           sources;
           assembled;
           archives;
           tables;
           flags;
           maps;
           cache;
         })

(* The `system` rows of [p]'s `c.coda` that apply to the build, in the
   order they are written: each row's number and the library it names. *)
let libraries p =
  List.filter_map
    (fun (row : Settings.row) ->
      if row.setting = Settings.System then Some (row.number, row.value) else None)
    p.rows

(* The C names every object of [p]'s defines: its assembled sources' and
   its archives' members'. *)
let object_defined p =
  List.concat_map (fun a -> a.contents.Objects.defined) p.assembled
  @ List.concat_map (fun a -> a.held.Objects.defined) p.archives

(* Every package's C, once the target's include directories are known
   from [cc]. *)
let compile_all ?cache ~work ~cc ~cpu ~triple ~target packages =
  (* A cache that cannot be written is no cache: the headers go in the
     build's own directory, and nothing is kept. *)
  let headers, cache =
    match cache with
    | Some c -> ( try (Compile.headers (Filename.concat c "foreign"), Some c) with Sys_error _ -> (Compile.headers work, None))
    | None -> (Compile.headers work, None)
  in
  match Probe.include_dirs ?cache ~dir:work ~cc ~triple target with
  | Error message -> Error { diagnostics = [ Diagnostic.about_invocation message ]; sources = [] }
  | Ok include_dirs ->
      let fixed = Compile.fixed_flags ~triple ~headers ~include_dirs in
      combine (List.map (compile_package ?cache ~fixed ~headers ~triple ~cpu) packages)

let no_c (dir, rows, _) =
  {
    dir;
    rows;
    headers = [];
    interface = C_interface.empty;
    sources = [];
    assembled = [];
    archives = [];
    tables = [];
    flags = [];
    maps = [];
    cache = None;
  }

let has_c (dir, rows, sources) =
  sources <> [] || Settings.interface_headers dir <> []
  || List.exists (fun (row : Settings.row) -> row.setting = Settings.Archive) rows

(* Each of [dirs]' C build, for a build for [target], its C compiled by the
   linked clang with the include directories [cc] searches for that
   target, and a source holding assembly emitted for [cpu], the processor
   the build tunes for. A package with no C needs nothing of [cc], so a
   build with no C anywhere never runs it. *)
let compile_packages ?(cache = Cache.dir ()) ~cc ~cpu ~target dirs =
  let triple = triple target in
  let ( let* ) = Result.bind in
  let* packages = combine (List.map (read_settings ~triple) dirs) in
  let* packages = combine (List.map with_sources packages) in
  if List.exists has_c packages then
    compile_all ?cache ~work:(work_dir ()) ~cc ~cpu ~triple ~target packages
  else Ok (List.map no_c packages)

(* The glue refused, or not written, as a diagnostic. *)
let glue_refused message = Error { diagnostics = [ Diagnostic.about_invocation message ]; sources = [] }
let glue_unwritten message = glue_refused (Printf.sprintf "the glue could not be written: %s" message)

(* One glue file, [text] for [header], written into [work] and compiled
   with [maps] and [flags]. What it is refused for names the header as the
   package's directory was given, [dir] being where it lies. *)
let glue_file p ~dir ~work ~maps ~flags (header, text) =
  let path = Filename.concat work (Filename.remove_extension (Filename.basename header) ^ ".glue.c") in
  match Out_channel.with_open_bin path (fun oc -> output_string oc text) with
  | exception Sys_error message -> glue_unwritten message
  | () ->
      let ( let* ) = Result.bind in
      let shown =
        match List.find_opt (fun (h, _) -> Filename.concat dir h = header) p.tables with
        | Some (h, _) -> Filename.concat p.dir h
        | None -> header
      in
      let* source = Compile.compile_source ?cache:p.cache ~maps flags path in
      let* source = linker_sets ~file:shown source in
      assembly ~header:shown source

(* [files] written into a directory of their own and compiled. *)
let glue_files p ~dir files =
  match Filename.temp_dir "zane-glue-" "" with
  | exception Sys_error message -> glue_unwritten message
  | work ->
      Fun.protect
        ~finally:(fun () -> try remove work with Sys_error _ -> ())
        (fun () ->
          let added = [ (dir, "/zane/pkg"); (work, "/zane/glue") ] in
          let maps = p.maps @ added and flags = p.flags @ Compile.map_flags added in
          combine (List.map (glue_file p ~dir ~work ~maps ~flags) files))

(* [p]'s glue for [entries] (Glue), each file compiled as its sources
   were, from the cache when it holds it. The files are written to a
   directory of their own, named `/zane/glue` in the module and the hash
   as the package's directory is named `/zane/pkg`, and each includes its
   header by the absolute path the package's directory map names; a path
   holding a double quote or a line break cannot be a quoted header name, and is
   refused. *)
let glue p (entries : Glue.entry list) =
  let dir = if Filename.is_relative p.dir then Filename.concat (Sys.getcwd ()) p.dir else p.dir in
  let files = Glue.files (List.map (fun (h, t) -> (Filename.concat dir h, t)) p.tables) entries in
  let quoted = String.exists (fun c -> c = '"' || c = '\n') in
  match List.find_opt (fun (header, _) -> quoted header) files with
  | _ when entries = [] -> Ok []
  | Some (header, _) ->
      glue_refused
        (Printf.sprintf "the interface header `%s` cannot be included by its path, which holds a `\"` or a line break"
           header)
  | None -> glue_files p ~dir files

(* The C entries and invokers of the function values C can call
   (docs/design/ffi.md F11, Glue.callbacks_file), compiled for [target] by
   the linked clang, from the cache when it holds them. The file includes
   nothing, so it needs no C library's headers. *)
let callbacks ?(cache = Cache.dir ()) ~target (entries : Glue.callback list) (invokers : Glue.invoker list) =
  let triple = triple target in
  match Filename.temp_dir "zane-callbacks-" "" with
  | exception Sys_error message -> glue_unwritten message
  | work ->
      Fun.protect
        ~finally:(fun () -> try remove work with Sys_error _ -> ())
        (fun () ->
          let headers, cache =
            match cache with
            | Some c -> ( try (Compile.headers (Filename.concat c "foreign"), Some c) with Sys_error _ -> (Compile.headers work, None))
            | None -> (Compile.headers work, None)
          in
          let maps = [ (work, "/zane/glue") ] in
          let flags = Compile.fixed_flags ~triple ~headers ~include_dirs:[] @ Compile.map_flags maps in
          let path = Filename.concat work "callbacks.c" in
          match Out_channel.with_open_bin path (fun oc -> output_string oc (Glue.callbacks_file entries invokers)) with
          | exception Sys_error message -> glue_unwritten message
          | () -> Compile.compile_source ?cache ~maps flags path)
