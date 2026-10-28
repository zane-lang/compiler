(* The C interface's front half (docs/design/ffi.md §1): each package's
   `c.coda`, and its C sources compiled for the build's target by the
   linked clang. *)

module Settings = Settings
module Probe = Probe
module Clang = Clang
module Compile = Compile
module Interface = Interface

(* What a package's C build is: the rows of its `c.coda` that apply to the
   build, its interface headers and what they declare, and its C sources
   compiled. *)
type package = {
  dir : string;
  rows : Settings.row list;
  headers : string list;
  interface : Interface.t;
  sources : Compile.source list;
}

type failure = Compile.failure = { diagnostics : Diagnostic.t list; sources : Source.Files.t }

(* The triple a build for [target] compiles C for, as LLVM normalizes it:
   the host's when [None]. *)
let triple target = Clang.normalize (match target with Some t -> t | None -> Clang.host_triple ())

(* A directory of its own for a build's probe and, without a cache, its
   headers; removed when [f] returns. *)
let with_work_dir f =
  let dir = Filename.temp_dir "zane-c-" "" in
  let rec remove path =
    if Sys.is_directory path then begin
      Array.iter (fun e -> remove (Filename.concat path e)) (Sys.readdir path);
      Sys.rmdir path
    end
    else Sys.remove path
  in
  Fun.protect ~finally:(fun () -> try remove dir with Sys_error _ -> ()) (fun () -> f dir)

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

(* One package's C: its interface headers read and its sources compiled,
   with the [fixed] flags and its own. *)
let compile_package ?cache ~fixed ~headers (dir, rows, sources) =
  let maps = Compile.prefix_maps ~dir ~headers in
  let flags = fixed @ Compile.map_flags maps @ Compile.package_flags dir rows in
  let interface_headers = Settings.interface_headers dir in
  let interface =
    combine (List.map (fun h -> Compile.interface flags (Filename.concat dir h)) interface_headers)
    |> Result.map (List.fold_left Interface.merge Interface.empty)
  in
  let compiled =
    combine (List.map (fun s -> Compile.compile_source ?cache ~maps flags (Filename.concat dir s)) sources)
  in
  both interface compiled
  |> Result.map (fun (interface, sources) -> { dir; rows; headers = interface_headers; interface; sources })

(* Every package's C, once the target's include directories are known
   from [cc]. *)
let compile_all ?cache ~work ~cc ~triple ~target packages =
  (* A cache that cannot be written is no cache: the headers go in the
     build's own directory, and nothing is kept. *)
  let headers, cache =
    match cache with
    | Some c -> ( try (Compile.headers (Filename.concat c "foreign"), Some c) with Sys_error _ -> (Compile.headers work, None))
    | None -> (Compile.headers work, None)
  in
  match Probe.include_dirs ?cache ~dir:work ~cc target with
  | Error message -> Error { diagnostics = [ Diagnostic.about_invocation message ]; sources = [] }
  | Ok include_dirs ->
      let fixed = Compile.fixed_flags ~triple ~headers ~include_dirs in
      combine (List.map (compile_package ?cache ~fixed ~headers) packages)

let no_c (dir, rows, _) = { dir; rows; headers = []; interface = Interface.empty; sources = [] }

let has_c (dir, _, sources) = sources <> [] || Settings.interface_headers dir <> []

(* Each of [dirs]' C build, for a build for [target], its C compiled by the
   linked clang with the include directories [cc] searches for that
   target. A package with no C needs nothing of [cc], so a build with no C
   anywhere never runs it. *)
let compile_packages ?(cache = Cache.dir ()) ~cc ~target dirs =
  let triple = triple target in
  let ( let* ) = Result.bind in
  let* packages = combine (List.map (read_settings ~triple) dirs) in
  let* packages = combine (List.map with_sources packages) in
  if List.exists has_c packages then
    with_work_dir (fun work -> compile_all ?cache ~work ~cc ~triple ~target packages)
  else Ok (List.map no_c packages)
