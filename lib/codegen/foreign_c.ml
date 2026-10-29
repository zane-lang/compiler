(* The packages' C code in the program (docs/design/ffi.md F4, F9, F13,
   F14): each package's C modules and glue linked into one module, its
   globals renamed, and the packages' modules linked together. An optimized
   build links that into the program's module before its passes run, so
   LLVM inlines across the two languages; an unoptimized one optimizes it
   alone and emits it as an object of its own, which the cache keeps. A
   package's archives' members and the objects its sources holding
   assembly were assembled into reach the link beside it, renamed with the
   names its module's globals take. *)

(* An `archive` row's static library: a hash of its bytes, and its members,
   each its name and its bytes. *)
type archive = { digest : string; members : (string * string) list }

(* A `system` row's library, by its name, and the row, as an error about it
   names the row. *)
type library = { name : string; row : string }

(* One package's C: the prefix its renamed globals take, its sources'
   modules and its glue's, each as bitcode with the hash the cache keys it
   by, and the symbols of the thunks the glue defines, after the target's
   global prefix. A thunk keeps its name, which is already the package's;
   any other function the glue defines, as an interface header's own
   definition, is renamed as the sources' are. Beside them, the objects its
   sources holding assembly were assembled into, each with the hash of the
   module it was made from, its archives, the C names those objects and
   archives define, and its `system` libraries. *)
type package = {
  prefix : string;
  sources : (string * string) list;
  glue : (string * string) list;
  thunks : string list;
  objects : (string * string) list;
  archives : archive list;
  defined : string list;
  libraries : library list;
}

(* What reaches the link beside the C module: the objects and archives of
   every package, renamed, each as its bytes. *)
type apart = { objects : string list; archives : string list }

let nothing_apart = { objects = []; archives = [] }

external rename : Llvm.llmodule -> string -> string -> string list -> string list -> string list
  = "zane_rename_c_globals"

external drop_defined : Llvm.llmodule -> Llvm.llmodule -> unit = "zane_drop_defined"
external write_archive : int -> (string * string) list -> (string, string) result
  = "zane_write_archive"

(* The bitcode [text] read into [ctx]. *)
let parse ctx text =
  let buffer = Llvm.MemoryBuffer.of_string text in
  Fun.protect
    ~finally:(fun () -> Llvm.MemoryBuffer.dispose buffer)
    (fun () ->
      try Llvm_bitreader.parse_bitcode ctx buffer
      with Llvm_bitreader.Error message -> Diagnostic.bug ("a C module the linked clang made does not read back: " ^ message))

(* [modules] linked into the first, for [triple] and [data_layout], and
   then [glue], each without the definitions the modules before it hold
   (zane_drop_defined): an interface header's own definition, which the
   glue compiles, is also compiled by every source that includes it. *)
let linked ?(glue = []) ~triple ~data_layout modules =
  match modules @ glue with
  | [] -> None
  | first :: rest ->
      List.iter
        (fun m ->
          Llvm.set_target_triple triple m;
          Llvm.set_data_layout data_layout m)
        (first :: rest);
      List.iter
        (fun m ->
          if List.memq m glue then drop_defined m first;
          Llvm_linker.link_modules first m)
        rest;
      Some first

(* The kind of static library [triple]'s linker reads, as
   zane_write_archive numbers them: Darwin's on Apple's targets, COFF's on
   Windows, GNU's elsewhere. *)
let archive_kind triple =
  let parts = String.split_on_char '-' triple in
  let has part = List.exists (fun p -> String.starts_with ~prefix:part p) parts in
  if has "darwin" || has "macos" || has "apple" || has "ios" then 1
  else if has "windows" then 2
  else 0

(* [p]'s objects and archives renamed, each symbol whose C name is in
   [names] taking [p]'s prefix after [global_prefix], as the module's
   globals of those names did: definitions and references alike. A symbol
   of any other name, such as the C library's, keeps it. *)
let renamed_apart ~triple ~global_prefix p names =
  let table = Hashtbl.create 64 in
  List.iter (fun n -> Hashtbl.replace table n ()) names;
  let by_name symbol =
    let g = String.length global_prefix in
    if String.length symbol >= g && String.sub symbol 0 g = global_prefix then
      let label = String.sub symbol g (String.length symbol - g) in
      if Hashtbl.mem table label then Some (global_prefix ^ p.prefix ^ label) else None
    else None
  in
  let one what bytes =
    Rewrite.rename ~rename:by_name bytes
    |> Result.map fst
    |> Result.map_error (Printf.sprintf "cannot rename %s: %s" what)
  in
  let ( let* ) = Result.bind in
  let rec all f = function
    | [] -> Ok []
    | x :: rest ->
        let* y = f x in
        let* ys = all f rest in
        Ok (y :: ys)
  in
  let member (name, bytes) = Result.map (fun b -> (name, b)) (one ("the archive member " ^ name) bytes) in
  let archive (a : archive) =
    let* members = all member a.members in
    write_archive (archive_kind triple) members
    |> Result.map_error (Printf.sprintf "cannot write a renamed archive: %s")
  in
  let* objects = all (fun (_, bytes) -> one "an object assembled from the package's C" bytes) p.objects in
  let* archives = all archive p.archives in
  Ok { objects; archives }

(* One package's C as one module, its globals renamed, in [ctx], with its
   objects and archives renamed to match. The names its objects define are
   renamed in the module first, declarations too, so the module's uses
   reach the objects' definitions; then every name renamed in the module
   renames the objects, so an object's uses reach the module's. *)
let package_module ctx ~triple ~data_layout p =
  let glue = List.map (fun (_, bc) -> parse ctx bc) p.glue in
  let sources = List.map (fun (_, bc) -> parse ctx bc) p.sources in
  let global_prefix = Walks.global_prefix data_layout in
  let m = linked ~glue ~triple ~data_layout sources in
  let names =
    match m with Some m -> rename m p.prefix global_prefix p.thunks p.defined | None -> []
  in
  let apart =
    if p.objects = [] && p.archives = [] then Ok nothing_apart
    else renamed_apart ~triple ~global_prefix p (p.defined @ names)
  in
  match apart with
  | Ok apart -> Ok (m, apart)
  | Error _ as error ->
      Option.iter Llvm.dispose_module m;
      error

(* Every package's C as one module in [ctx], or [None] when there is none,
   and every package's objects and archives. *)
let program_module ctx ~triple ~data_layout packages =
  let rec each modules apart = function
    | [] -> Ok (linked ~triple ~data_layout (List.rev modules), apart)
    | p :: rest -> (
        match package_module ctx ~triple ~data_layout p with
        | Error _ as error ->
            List.iter Llvm.dispose_module modules;
            error
        | Ok (m, (a : apart)) ->
            let apart = { objects = apart.objects @ a.objects; archives = apart.archives @ a.archives } in
            each (Option.to_list m @ modules) apart rest)
  in
  each [] nothing_apart packages

(* Every package's `system` libraries, in the order the packages and their
   rows come. *)
let libraries packages = List.concat_map (fun p -> p.libraries) packages

(* What the object an unoptimized build emits for the C is kept under: the
   packages' prefixes and the hashes of their modules, objects and
   archives, for [triple], from the compiler [compiler] names, whose
   renaming and passes made it. *)
let key ~triple ~compiler packages =
  Digest.to_hex
    (Digest.string
       (String.concat "\000"
          ("c-object" :: triple :: compiler
          :: List.concat_map
               (fun p ->
                 (p.prefix :: List.map fst (p.sources @ p.glue @ p.objects))
                 @ List.map (fun (a : archive) -> a.digest) p.archives
                 @ [ "" ])
               packages)))
