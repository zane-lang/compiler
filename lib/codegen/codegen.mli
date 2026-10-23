(** Codegen: the CGT to an LLVM module, and the module to an object file or
    an executable linked with the C runtime (docs/design/lowering.md). Its
    failures are about the build -- a target LLVM does not know, a link that
    failed -- and are messages, not diagnostics. *)

(** [f] run on the program's module for [target], the host when it is
    absent, with that target's triple and data layout. The module and its
    context live only while [f] runs: both are disposed when it returns or
    raises, and when emitting the program fails, so nothing may keep the
    module past it. The module with the program's
    entry also defines the size in bytes of each context's range of frames,
    the main context's and each spawned call's; each takes its default when
    absent. With [pack], an aggregate that fits in the registers a call
    gives it passes as packed 8-byte words rather than by address
    (docs/design/lowering.md §9); off when absent. With [version], each
    loop over elements is emitted twice for the optimized passes
    (docs/design/lowering.md §9, "The passes"); off when absent. *)
val with_program :
  ?target:string ->
  ?pack:bool ->
  ?memoize:bool ->
  ?version:bool ->
  ?fixed_region:int ->
  ?spawned_fixed_region:int ->
  Cgt.Nodes.Program.t ->
  (Llvm.llmodule -> ('a, string) result) ->
  ('a, string) result

(** How many contexts [with_program] has made and not yet disposed: zero
    whenever no build is running. For the tests. *)
val live_contexts : unit -> int

(** The processor [prepare] tunes code for on [target], the host when it is
    absent: [x86-64] on any x86-64 target, [core-avx2] on [x86_64h], else
    LLVM's default, [""]. *)
val target_cpu : ?target:string -> unit -> (string, string) result

(** The module's text, as [prepare] left it, copied into an OCaml string
    that outlives the module. *)
val ir : Llvm.llmodule -> string

(** Which build of a tiered pair a module is (docs/design/tiers.md): the
    plain program whose calls go through slots, or the optimized library
    that fills them. A build that is neither is [Plain]. *)
type tier = Tiers.tier = Plain | Tier0 | Tier1

(** Readies a module [with_program] made for [target] to be written, and runs the
    optimizer when [optimize] or for [Tier1]. *)
val prepare : ?target:string -> ?optimize:bool -> ?tier:tier -> Llvm.llmodule -> (unit, string) result

val object_file :
  ?target:string -> ?optimize:bool -> ?tier:tier -> Llvm.llmodule -> string -> (unit, string) result

(** An executable at the given path, linked with the runtime and the objects
    in [link]. *)
val executable :
  ?target:string ->
  ?optimize:bool ->
  ?tier:tier ->
  ?link:string list ->
  Llvm.llmodule ->
  string ->
  (unit, string) result

(** Tier 1 of a tiered build: the module optimized into the shared library
    at the given path, which tier 0 loads while it runs, or the one the
    cache keeps for the same module (docs/design/tiers.md). *)
val shared_library : ?target:string -> Llvm.llmodule -> string -> (unit, string) result

(** The runtime compiled for [target] into the directory a released
    toolchain bundles it in, under the name a build for that target, with
    the same [optimize], looks for there (docs/design/lowering.md §7). *)
val bundle_runtime : target:string -> optimize:bool -> string -> (unit, string) result
