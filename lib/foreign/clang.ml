(* The linked clang (clang_stubs.cpp). A command line is clang's driver's,
   its first word the driver's name; a run gives what the front end made
   and the errors it reported. *)

(* One error the front end reported, at a line and column of [file], both
   counted from one; [file] is empty for one about the command itself. *)
type problem = { file : string; line : int; column : int; message : string }

(* What a run made, meaningful when [ok]. *)
type run = { ok : bool; output : string; problems : problem list }

external compile_raw : string array -> bool * string * (string * int * int * string) list = "zane_clang_compile"
external preprocess_raw : string array -> bool * string * (string * int * int * string) list = "zane_clang_preprocess"
external interface_raw : string array -> bool * string * (string * int * int * string) list = "zane_clang_interface"
external version : unit -> string = "zane_clang_version"
external host_triple : unit -> string = "zane_host_triple"
external triple_parts : string -> string * string * string * string = "zane_triple_parts"

let of_raw (ok, output, problems) =
  { ok; output; problems = List.map (fun (file, line, column, message) -> { file; line; column; message }) problems }

(* The driver's name. The linked driver finds nothing through it: every
   directory a compilation searches is given on the command line. *)
let driver = "clang"

(* The module [args]' one source compiles to, as bitcode. *)
let compile args = of_raw (compile_raw (Array.of_list (driver :: args)))

(* [args]' one source preprocessed, with its line markers. *)
let preprocess args = of_raw (preprocess_raw (Array.of_list (driver :: args)))

(* What [args]' one source, an interface header, declares, as the text
   Interface reads. *)
let interface args = of_raw (interface_raw (Array.of_list (driver :: args)))

(* [triple] as LLVM normalizes it. *)
let normalize triple =
  let normal, _, _, _ = triple_parts triple in
  normal

(* Whether two triples name one ABI: the same architecture, operating
   system and environment, as LLVM reads each. The vendor is left out,
   since normalizing keeps it (`pc` stays, a missing one becomes
   `unknown`) and it names no ABI on these targets. *)
let same_abi a b =
  let _, arch_a, os_a, env_a = triple_parts a and _, arch_b, os_b, env_b = triple_parts b in
  arch_a = arch_b && os_a = os_b && env_a = env_b
