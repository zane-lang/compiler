(* The packages' C code in the program (docs/design/ffi.md F9, F13, F14):
   each package's C modules and glue linked into one module, its globals
   renamed, and the packages' modules linked together. An optimized build
   links that into the program's module before its passes run, so LLVM
   inlines across the two languages; an unoptimized one optimizes it alone
   and emits it as an object of its own, which the cache keeps. *)

(* One C module: its bitcode, the hash the cache keys it by, and the
   files its code came from, by their real paths: a source's own and the
   headers it includes, or the interface header a glue module compiles. *)
type c_module = { key : string; bitcode : string; files : string list }

(* One package's C: the prefix its renamed globals take, its sources'
   modules and its glue's, and the symbols of the thunks the glue defines,
   after the target's global prefix. A thunk keeps its name, which is
   already the package's; any other function the glue defines, as an
   interface header's own definition, is renamed as the sources' are. *)
type package = { prefix : string; sources : c_module list; glue : c_module list; thunks : string list }

external rename : Llvm.llmodule -> string -> string -> string list -> unit = "zane_rename_c_globals"
external constructors : Llvm.llmodule -> string list = "zane_c_constructors"
external drop_defined : Llvm.llmodule -> Llvm.llmodule -> string list -> unit = "zane_drop_defined"

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

(* One package's C as one module, its globals renamed, in [ctx]. *)
let package_module ctx ~triple ~data_layout p =
  let parsed = List.map (fun c -> (c, parse ctx c.bitcode)) in
  let sources = parsed p.sources in
  (* Read before the link renames a source's local functions. *)
  let runs = List.map (fun (c, m) -> (c.files, constructors m)) sources in
  let run_by (g : c_module) =
    List.concat_map (fun (files, run) -> if List.exists (fun h -> List.mem h files) g.files then run else []) runs
  in
  let glue = List.map (fun (g, m) -> (m, run_by g)) (parsed p.glue) in
  Option.map
    (fun m ->
      rename m p.prefix (Emit.global_prefix data_layout) p.thunks;
      m)
    (linked ~glue ~triple ~data_layout (List.map snd sources))

(* Every package's C as one module in [ctx], or [None] when there is none. *)
let program_module ctx ~triple ~data_layout packages =
  linked ~triple ~data_layout (List.filter_map (package_module ctx ~triple ~data_layout) packages)

(* What the object an unoptimized build emits for the C is kept under: the
   packages' prefixes and the hashes of their modules, for [triple], from
   the compiler [compiler] names, whose renaming and passes made it. *)
let key ~triple ~compiler packages =
  Digest.to_hex
    (Digest.string
       (String.concat "\000"
          ("c-object" :: triple :: compiler
          :: List.concat_map (fun p -> p.prefix :: List.map (fun c -> c.key) (p.sources @ p.glue) @ [ "" ]) packages)))
