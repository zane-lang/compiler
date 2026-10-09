(** Codegen: the CGT to an LLVM module, and the module to an object file or
    an executable linked with the C runtime (docs/design/lowering.md). Its
    failures are about the build -- a target LLVM does not know, a link that
    failed -- and are messages, not diagnostics. *)

(** The module with the program's entry also defines the size in bytes of
    each context's range of frames, the main context's and each spawned
    call's; each takes its default when absent. *)
val emit : ?fixed_region:int -> ?spawned_fixed_region:int -> Cgt.Nodes.Program.t -> Llvm.llmodule

(** The processor [prepare] tunes code for on [target], the host when it is
    absent: [x86-64] on any x86-64 target, [core-avx2] on [x86_64h], else
    LLVM's default, [""]. *)
val target_cpu : ?target:string -> unit -> (string, string) result

(** The module's text, once [prepare] has set its target. *)
val ir : Llvm.llmodule -> string

(** Sets the module's target, the host's when [target] is absent, and runs
    the optimizer when [optimize]. *)
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
