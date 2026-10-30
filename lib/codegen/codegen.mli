(** Codegen: the CGT to an LLVM module, and the module to an object file or
    an executable linked with the C runtime (docs/design/lowering.md). Its
    failures are about the build -- a target LLVM does not know, a link that
    failed -- and are messages, not diagnostics. *)

(** One C module: its bitcode, the hash the cache keys it by, and the
    files its code came from, by their real paths: a source's own and the
    headers it includes, or the interface header a glue module compiles. *)
type c_module = { key : string; bitcode : string; files : string list }

(** A package's `archive` row's static library: a hash of its bytes, and
    its members, each its name and its bytes (docs/design/ffi.md F4). *)
type c_archive = { digest : string; members : (string * string) list }

(** A package's `system` row's library, and the row, as an error about it
    names it. *)
type c_library = { name : string; row : string }

(** One package's C code for the program (docs/design/ffi.md F4, F9): the
    prefix its globals are renamed with, its sources' and its glue's
    modules, and the symbols of the thunks its glue defines, which keep
    their names; the objects its sources holding assembly were assembled
    into, each with the module it was made from, its archives, the C names those
    objects and archives define, and its `system` libraries. A stamped
    dependency's C is in its objects, so it has its archives and libraries,
    and names the C names those objects define as its archives'
    (docs/design/ffi.md F15); with [labels], the package as its publisher's
    glue labels named it, it also has the sources' and glue modules an
    optimized build retains (F13). *)
type c_package = {
  prefix : string;
  sources : c_module list;
  glue : c_module list;
  thunks : string list;
  objects : (c_module * string) list;
  archives : c_archive list;
  defined : string list;
  libraries : c_library list;
  labels : string option;
}

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
    loop over elements that the optimized passes can split is emitted
    twice (Emit.versioned, docs/design/lowering.md §9, "The passes"); off
    when absent. [c] is the packages' C code, which an optimized build, a
    tier and an object link into the module, and an unoptimized executable
    links as an object of its own (docs/design/ffi.md F13, F14). *)
val with_program :
  ?target:string ->
  ?pack:bool ->
  ?memoize:bool ->
  ?version:bool ->
  ?fixed_region:int ->
  ?spawned_fixed_region:int ->
  ?c:c_package list ->
  Cgt.Nodes.Program.t ->
  (Llvm.llmodule -> ('a, string) result) ->
  ('a, string) result

(** [f] run on the packages' C modules for [target], the host when it is
    absent, as the program links them: each package's renamed and linked,
    and the retained modules of stamped dependencies (docs/design/ffi.md
    F13). Stage 5 evaluates them (F16). None are given when a package links
    objects or archives apart, whose constructors may write the modules'
    globals as the program starts. They and their context are disposed
    when [f] returns or raises, so nothing may keep them past it. *)
val with_c_modules :
  ?target:string -> c_package list -> (Llvm.llmodule list -> 'a) -> ('a, string) result

(** How many contexts [with_program] has made and not yet disposed: zero
    whenever no build is running. For the tests. *)
val live_contexts : unit -> int

(** The processor [prepare] tunes code for on [target], the host when it is
    absent: [x86-64] on any x86-64 target, [core-avx2] on [x86_64h], else
    LLVM's default, [""]. *)
val target_cpu : ?target:string -> unit -> (string, string) result

(** The global prefix of [target]'s symbols, as its data layout says: `_`
    on Mach-O, none on ELF and 64-bit COFF. A glue entry's `__asm__` label
    is its symbol after it (docs/design/ffi.md F8). *)
val global_prefix : ?target:string -> unit -> (string, string) result

(** The C compiler a build runs: `ZANE_CC`, else `clang`. It links, and
    it says where a target's C headers are (docs/design/ffi.md F1). *)
val c_compiler : unit -> string

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
