(** Codegen: the CGT to an LLVM module, and the module to an object file or
    an executable linked with the C runtime (docs/design/lowering.md). Its
    failures are about the build -- a target LLVM does not know, a link that
    failed -- and are messages, not diagnostics. *)

(** The program's module for [target], the host when it is absent, with
    that target's triple and data layout. The module with the program's
    entry also defines the size in bytes of each context's range of frames,
    the main context's and each spawned call's; each takes its default when
    absent. With [pack], an aggregate that fits in the registers a call
    gives it passes as packed 8-byte words rather than by address
    (docs/design/lowering.md §9); off when absent. *)
val emit :
  ?target:string ->
  ?pack:bool ->
  ?fixed_region:int ->
  ?spawned_fixed_region:int ->
  Cgt.Nodes.Program.t ->
  (Llvm.llmodule, string) result

(** The processor [prepare] tunes code for on [target], the host when it is
    absent: [x86-64] on any x86-64 target, [core-avx2] on [x86_64h], else
    LLVM's default, [""]. *)
val target_cpu : ?target:string -> unit -> (string, string) result

(** The module's text, as [prepare] left it. *)
val ir : Llvm.llmodule -> string

(** Readies a module [emit] made for [target] to be written, and runs the
    optimizer when [optimize]. *)
val prepare : ?target:string -> ?optimize:bool -> Llvm.llmodule -> (unit, string) result

val object_file :
  ?target:string -> ?optimize:bool -> Llvm.llmodule -> string -> (unit, string) result

(** An executable at the given path, linked with the runtime and the objects
    in [link]. *)
val executable :
  ?target:string ->
  ?optimize:bool ->
  ?link:string list ->
  Llvm.llmodule ->
  string ->
  (unit, string) result
