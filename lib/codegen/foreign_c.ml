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

(* One C module: its bitcode, the hash the cache keys it by, and the
   files its code came from, by their real paths: a source's own and the
   headers it includes, or the interface header a glue module compiles. *)
type c_module = { key : string; bitcode : string; files : string list }

(* One package's C: the prefix its renamed globals take, its sources'
   modules and its glue's, and the symbols of the thunks the glue defines,
   after the target's global prefix. A thunk keeps its name, which is
   already the package's; any other function the glue defines, as an
   interface header's own definition, is renamed as the sources' are.
   Beside them, the objects its sources holding assembly were assembled
   into, each with the module it was made from, its archives, the C names
   those objects and archives define, and its `system` libraries.

   A stamped dependency's modules, when the consumer retains them
   (docs/design/ffi.md F13), come with [labels]: the package as its glue's
   labels name it, which is how its publisher named it, `!` before a
   library's own package, so that the glue compiles to the publisher's
   module. Its thunks take the package's stamped names back before the
   module is linked, and every body in it is retained, never emitted. *)
type package = {
  prefix : string;
  sources : c_module list;
  glue : c_module list;
  thunks : string list;
  objects : (c_module * string) list;
  archives : archive list;
  defined : string list;
  libraries : library list;
  labels : string option;
}

(* What reaches the link beside the C module: the objects and archives of
   every package, renamed, each as its bytes. *)
type apart = { objects : string list; archives : string list }

let nothing_apart = { objects = []; archives = [] }

external rename : Llvm.llmodule -> string -> string -> string list -> string list -> string list
  = "zane_rename_c_globals"

external constructors : Llvm.llmodule -> string list = "zane_c_constructors"
external drop_defined : Llvm.llmodule -> Llvm.llmodule -> string list -> unit = "zane_drop_defined"
external drop_defined_apart : Llvm.llmodule -> string -> string list -> unit = "zane_drop_defined_apart"
external share_state : Llvm.llmodule -> Llvm.llmodule -> string -> unit = "zane_share_state"
external localize_shared : Llvm.llmodule -> unit = "zane_localize_shared"
external retain : Llvm.llmodule -> bool = "zane_retain_c"

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
   glue compiles, is also compiled by every source that includes it. Each
   glue module comes with the constructors and destructors of the sources
   that include its header. *)
let linked ?(glue = []) ~triple ~data_layout modules =
  match modules @ List.map fst glue with
  | [] -> None
  | first :: rest ->
      List.iter
        (fun m ->
          Llvm.set_target_triple triple m;
          Llvm.set_data_layout data_layout m)
        (first :: rest);
      List.iter
        (fun m ->
          Option.iter (drop_defined m first) (List.assq_opt m glue);
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
    if String.starts_with ~prefix:global_prefix symbol then
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

(* The package [p]'s name, its prefix without the `$%c$` after it. *)
let package_name p = String.sub p.prefix 0 (String.length p.prefix - 4)

(* Each thunk of the glue modules [glue], whose label names the package as
   [labels] does, named by its label with the package's own name instead,
   wherever the label names it: before the verb and in its own types.
   LLVM writes a label with a leading \1 and the target's global prefix
   spelled out where the target has one, and as it is elsewhere. *)
let relabel ~global_prefix p glue labels =
  let own = package_name p in
  let marked = "\001" ^ global_prefix in
  let before = labels ^ "$" in
  let relabelled name =
    let mark = if String.starts_with ~prefix:marked name then marked else "" in
    let label = String.sub name (String.length mark) (String.length name - String.length mark) in
    if String.starts_with ~prefix:before label then Some (mark ^ Rewrite.respell ~from:before ~into:(own ^ "$") label)
    else None
  in
  List.iter
    (Llvm.iter_functions (fun f -> Option.iter (fun n -> Llvm.set_value_name n f) (relabelled (Llvm.value_name f))))
    glue

(* [packages] without what a build that compiles the C apart leaves out:
   the retained modules of stamped dependencies, whose bodies only an
   optimized build linking the C in can inline (F13, F14). *)
let unretained packages =
  List.map (fun p -> if p.labels = None then p else { p with sources = []; glue = []; thunks = []; labels = None }) packages

(* One package's C as one module, its globals renamed, in [ctx], with its
   objects and archives renamed to match. The names its objects define are
   renamed in the module first, declarations too, so the module's uses
   reach the objects' definitions; then every name renamed in the module
   renames the objects, so an object's uses reach the module's. *)
let package_module ctx ~triple ~data_layout p =
  let parsed = List.map (fun c -> (c, parse ctx c.bitcode)) in
  let sources = parsed p.sources in
  let glue = parsed p.glue in
  let includes (g : c_module) (c : c_module) = List.exists (fun h -> List.mem h c.files) g.files in
  (* A glue module's private state is the one source's including its
     header (Foreign refuses one that several sources define), each
     source's shared under a tag of its own. *)
  List.iter
    (fun (g, gm) ->
      List.iteri (fun i (c, m) -> if includes g c then share_state gm m (string_of_int i)) sources)
    glue;
  (* Read before the link renames a source's local functions. A source
     assembled apart runs its constructors from its object, so a header it
     includes runs them there. *)
  let assembled_runs (c, _) =
    let m = parse ctx c.bitcode in
    Fun.protect ~finally:(fun () -> Llvm.dispose_module m) (fun () -> (c, constructors m))
  in
  let runs = List.map (fun (c, m) -> (c, constructors m)) sources @ List.map assembled_runs p.objects in
  let run_by g = List.concat_map (fun (c, run) -> if includes g c then run else []) runs in
  let global_prefix = Walks.global_prefix data_layout in
  let glue_module (g, m) =
    if p.defined <> [] then drop_defined_apart m global_prefix p.defined;
    (m, run_by g)
  in
  let glue = List.map glue_module glue in
  Option.iter (relabel ~global_prefix p (List.map fst glue)) p.labels;
  (* With no source in the module, the glue is linked into an empty one,
     so each glue module is still linked as one after the sources. *)
  let base = match sources with [] when glue <> [] -> [ Llvm.create_module ctx "c" ] | _ -> List.map snd sources in
  let m = linked ~glue ~triple ~data_layout base in
  let names =
    match m with
    | Some m ->
        localize_shared m;
        rename m p.prefix global_prefix p.thunks p.defined
    | None -> []
  in
  let m =
    match m with
    | Some c when p.labels <> None && not (retain c) ->
        Llvm.dispose_module c;
        None
    | m -> m
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
   the retained modules of stamped dependencies apart from it (F13), and
   every package's objects and archives. LLVM's linker takes an
   `available_externally` body only into a module that already uses it, so
   a retained module is linked into the program's own, never into the
   others' C. *)
let program_module ctx ~triple ~data_layout packages =
  let rec each modules retained apart = function
    | [] -> Ok (linked ~triple ~data_layout (List.rev modules), List.rev retained, apart)
    | p :: rest -> (
        match package_module ctx ~triple ~data_layout p with
        | Error _ as error ->
            List.iter Llvm.dispose_module (modules @ retained);
            error
        | Ok (m, (a : apart)) ->
            let apart = { objects = apart.objects @ a.objects; archives = apart.archives @ a.archives } in
            if p.labels = None then each (Option.to_list m @ modules) retained apart rest
            else each modules (Option.to_list m @ retained) apart rest)
  in
  each [] [] nothing_apart packages

(* Every package's `system` libraries, in the order the packages and their
   rows come. *)
let libraries packages = List.concat_map (fun p -> p.libraries) packages

(* What the object an unoptimized build emits for the C is kept under: the
   packages' prefixes, the hashes of their modules, objects and archives,
   and the names those objects and archives are renamed by, for [triple],
   from the compiler [compiler] names, whose renaming and passes made it. *)
let key ~triple ~compiler packages =
  Digest.to_hex
    (Digest.string
       (String.concat "\000"
          ("c-object" :: triple :: compiler
          :: List.concat_map
               (fun p ->
                 (p.prefix :: List.map (fun c -> c.key) (p.sources @ p.glue))
                 @ List.map (fun (c, _) -> c.key) p.objects
                 @ List.map (fun (a : archive) -> a.digest) p.archives
                 @ ("" :: List.sort_uniq compare p.defined)
                 @ [ "" ])
               packages)))
