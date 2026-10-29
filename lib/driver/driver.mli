(** The pipeline as a front end runs it (docs/design/stages.md): each step a
    result whose failure is every problem it found, with the text of the
    files they point into. *)

type failure = { diagnostics : Diagnostic.t list; sources : Source.Files.t }

(** A failure of [diagnostics], pointing into [sources]. *)
val fail : ?sources:Source.Files.t -> Diagnostic.t list -> ('a, failure) result

(** Each diagnostic as a person reads it, in order. *)
val render : failure -> string list

(** The packages of the build, the first the root unless [root] is false,
    as in a library build, which has none (packages.md §6.1). [stamps]
    gives a package its stamp by path, and must name exactly one package
    each with a value that is a stamp; [imports] gives each package's
    import keys (docs/design/separate-compilation.md C6, C10). *)
val assemble :
  ?root:bool ->
  ?imports:(string * string * string) list ->
  ?stamps:(string * string) list ->
  Tst.Assembly.request list ->
  (Tst.Assembly.package list, failure) result

(** Each package's C compiled for [target], the host when it is absent:
    its `c.coda` read, and its C sources compiled by the linked clang
    (docs/design/ffi.md §1). *)
val c_code : ?target:string -> Tst.Assembly.package list -> (Foreign.package list, failure) result

(** Semantics, which gives no tree when it found a problem. *)
val check : ?c:Foreign.package list -> Tst.Assembly.package list -> (Tst.Nodes.Program.t, failure) result

(** That the root declares a `main`: the one check for it, which lowering
    takes as given. *)
val require_main : Tst.Nodes.Program.t -> (unit, failure) result

(** That a build with [root], as `--root` or `--no-root` gives it, may be
    built into an executable: one without a root may not. *)
val buildable : bool option -> (unit, failure) result

(** The size in bytes of the range each context reserves for its frames:
    the main context's, from `--fixed-region`, and each spawned call's, from
    `--spawned-fixed-region`. [None] takes the default. *)
type regions = { fixed : int option; spawned : int option }

(** Stage 4, with the bodies of stamped dependencies' functions taken in
    for LLVM to inline. Without [root], it lowers from every function the
    build declares rather than from the root's `main`. A type no main
    context's range of [regions] could hold is refused where it is named. *)
val lower :
  ?regions:regions ->
  root:bool ->
  Tst.Assembly.package list ->
  Tst.Nodes.Program.t ->
  (Cgt.Nodes.Program.t, failure) result

(** The C code each unstamped package of the build compiles into this
    object, with the glue for the thunks the tree's foreign calls go through
    (docs/design/ffi.md F8, F9), for [target], the host when it is absent:
    [c] is [c_code]'s for the packages. A build without [root] is a
    library's, whose C globals are renamed for fetching to stamp. *)
val c_modules :
  ?target:string ->
  root:bool ->
  Tst.Assembly.package list ->
  Foreign.package list ->
  Cgt.Nodes.Program.t ->
  (Codegen.c_package list, failure) result

(** Stage 5 when [optimize], and the tree as it is otherwise. *)
val optimize : optimize:bool -> Cgt.Nodes.Program.t -> Cgt.Nodes.Program.t

(** The LLVM module's text. Each of these builds for [target], the host when
    it is absent, and with [pack] passes small aggregates as packed words
    (docs/design/lowering.md §9, `--pack-aggregates`). *)
val ir :
  ?target:string ->
  ?pack:bool ->
  ?memoize:bool ->
  ?c:Codegen.c_package list ->
  ?regions:regions ->
  optimize:bool ->
  Cgt.Nodes.Program.t ->
  (string, failure) result

(** An executable; with [tiered], tier 0 of a tiered build, whose calls go
    through slots that tier 1 fills while it runs (docs/design/tiers.md). *)
val executable :
  ?target:string ->
  ?pack:bool ->
  ?memoize:bool ->
  ?c:Codegen.c_package list ->
  ?regions:regions ->
  ?tiered:bool ->
  optimize:bool ->
  link:string list ->
  Cgt.Nodes.Program.t ->
  string ->
  (unit, failure) result

(** Tier 1 of a tiered build: the program optimized into a shared library
    for tier 0 to load (`--tier-up`, docs/design/tiers.md). *)
val tier_up :
  ?target:string ->
  ?pack:bool ->
  ?memoize:bool ->
  ?c:Codegen.c_package list ->
  ?regions:regions ->
  Cgt.Nodes.Program.t ->
  string ->
  (unit, failure) result

val object_file :
  ?target:string ->
  ?pack:bool ->
  ?memoize:bool ->
  ?c:Codegen.c_package list ->
  ?regions:regions ->
  optimize:bool ->
  Cgt.Nodes.Program.t ->
  string ->
  (unit, failure) result

(** The runtime compiled for the target into a released toolchain's
    directory of them (`--bundle-runtime`, docs/design/lowering.md §7). *)
val bundle_runtime : target:string -> optimize:bool -> string -> (unit, failure) result

(** The name of a file beside the output to write it under first, drawn
    from the random source. *)
val temporary_name : Random.State.t -> string -> string

(** [rewrite_object ~stamps ~rewrite ~input ~output] writes [output] as
    [rewrite] makes it from [input]'s contents, once each of [stamps] is a
    stamp and, for two, they are versions of one package (`--rewrite` and
    `--remap`, docs/design/separate-compilation.md C9, C11). The object is
    written beside [output] under a name drawn from [random] and renamed into
    place, so a failure leaves an existing [output] as it was; a name that
    is already taken is left alone and another drawn, up to eight. *)
val rewrite_object :
  random:Random.State.t ->
  stamps:string list ->
  rewrite:(string -> (string * 'a, string) result) ->
  input:string ->
  output:string ->
  (unit, failure) result
