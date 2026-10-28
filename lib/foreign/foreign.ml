(* The C interface's front half (docs/design/ffi.md §1): each package's
   `c.coda`, and its C sources compiled for the build's target by the
   linked clang. *)

module Settings = Settings
module Probe = Probe
module Clang = Clang
module Compile = Compile

(* What a package's C build is: the rows of its `c.coda` that apply to the
   build, its interface headers, and its C sources compiled. *)
type package = {
  dir : string;
  rows : Settings.row list;
  headers : string list;
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

(* Each of [dirs]' C build, for a build for [target], its C compiled by the
   linked clang with the include directories [cc] searches for that
   target. A package with no C needs nothing of [cc], so a build with no C
   anywhere never runs it. *)
let compile_packages ?(cache = Cache.dir ()) ~cc ~target dirs =
  let triple = triple target in
  let read dir =
    let coda = Filename.concat dir Settings.file_name in
    let sources () = match Cache.read coda with Some text -> [ (coda, text) ] | None -> [] in
    Result.map_error (fun diagnostics -> { diagnostics; sources = sources () }) (Settings.read ~triple dir)
    |> Result.map (fun rows -> (dir, rows))
  in
  match combine (List.map read dirs) with
  | Error _ as e -> e
  | Ok packages -> (
      let with_sources (dir, rows) =
        Settings.sources dir rows
        |> Result.map_error (fun diagnostics -> { diagnostics; sources = [] })
        |> Result.map (fun sources -> (dir, rows, sources))
      in
      match combine (List.map with_sources packages) with
      | Error _ as e -> e
      | Ok packages ->
          with_work_dir (fun work ->
              let has_c = List.exists (fun (_, _, sources) -> sources <> []) packages in
              let compiled () =
                let root = match cache with Some c -> Filename.concat c "foreign" | None -> work in
                let headers = Compile.headers root in
                match Probe.include_dirs ?cache ~dir:work ~cc target with
                | Error message -> Error { diagnostics = [ Diagnostic.about_invocation message ]; sources = [] }
                | Ok include_dirs ->
                    let fixed = Compile.fixed_flags ~triple ~headers ~include_dirs in
                    combine
                      (List.map
                         (fun (dir, rows, sources) ->
                           let maps = Compile.prefix_maps ~dir ~headers in
                           let flags = fixed @ Compile.map_flags maps @ Compile.package_flags dir rows in
                           combine
                             (List.map
                                (fun s -> Compile.compile_source ?cache ~maps flags (Filename.concat dir s))
                                sources)
                           |> Result.map (fun sources ->
                                  { dir; rows; headers = Settings.interface_headers dir; sources }))
                         packages)
              in
              if has_c then compiled ()
              else
                Ok
                  (List.map
                     (fun (dir, rows, _) -> { dir; rows; headers = Settings.interface_headers dir; sources = [] })
                     packages)))
