(* The packages' C code in the program (docs/design/ffi.md F9, F13, F14):
   each package's C modules and glue linked into one module, its globals
   renamed, and the packages' modules linked together. An optimized build
   links that into the program's module before its passes run, so LLVM
   inlines across the two languages; an unoptimized one optimizes it alone
   and emits it as an object of its own, which the cache keeps. *)

(* One package's C: the prefix its renamed globals take, its sources'
   modules and its glue's, each as bitcode with the hash the cache keys it
   by. *)
type package = { prefix : string; sources : (string * string) list; glue : (string * string) list }

external rename : Llvm.llmodule -> string -> string -> string list -> unit = "zane_rename_c_globals"

(* The bitcode [text] read into [ctx]. *)
let parse ctx text =
  let buffer = Llvm.MemoryBuffer.of_string text in
  Fun.protect
    ~finally:(fun () -> Llvm.MemoryBuffer.dispose buffer)
    (fun () ->
      try Llvm_bitreader.parse_bitcode ctx buffer
      with Llvm_bitreader.Error message -> Diagnostic.bug ("a C module the linked clang made does not read back: " ^ message))

(* The functions [m] defines. *)
let defined m =
  Llvm.fold_left_functions (fun acc f -> if Llvm.is_declaration f then acc else Llvm.value_name f :: acc) [] m

(* [modules] linked into the first, for [triple] and [data_layout]. *)
let linked ~triple ~data_layout = function
  | [] -> None
  | first :: rest ->
      List.iter
        (fun m ->
          Llvm.set_target_triple triple m;
          Llvm.set_data_layout data_layout m)
        (first :: rest);
      List.iter (Llvm_linker.link_modules first) rest;
      Some first

(* One package's C as one module, its globals renamed, in [ctx]. *)
let package_module ctx ~triple ~data_layout p =
  let glue = List.map (fun (_, bc) -> parse ctx bc) p.glue in
  let entries = List.concat_map defined glue in
  let sources = List.map (fun (_, bc) -> parse ctx bc) p.sources in
  Option.map
    (fun m ->
      rename m p.prefix (Emit.global_prefix data_layout) entries;
      m)
    (linked ~triple ~data_layout (sources @ glue))

(* Every package's C as one module in [ctx], or [None] when there is none. *)
let program_module ctx ~triple ~data_layout packages =
  linked ~triple ~data_layout (List.filter_map (package_module ctx ~triple ~data_layout) packages)

(* What the object an unoptimized build emits for the C is kept under: the
   packages' prefixes and the hashes of their modules, for [triple]. *)
let key ~triple packages =
  Digest.to_hex
    (Digest.string
       (String.concat "\000"
          ("c-object" :: triple
          :: List.concat_map (fun p -> p.prefix :: List.map fst (p.sources @ p.glue) @ [ "" ]) packages)))
