(** The pipeline as a front end runs it (docs/design/stages.md). Each step
    returns a result whose failure holds every problem the step found, with
    the text of the files the problems point into. *)

type failure = { diagnostics : Diagnostic.t list; sources : Source.Files.t }

(** A failure of [diagnostics], pointing into [sources]. *)
val fail : ?sources:Source.Files.t -> Diagnostic.t list -> ('a, failure) result

(** Each diagnostic as a person reads it, in order. *)
val render : failure -> string list

(** The packages of the build. The first package is the root, unless
    [root] is false, as in a library build, which has no root (packages.md
    §6.1). [buffers] is the text an editor holds for a file, by path,
    read instead of the file (docs/design/language-server.md). [stamps]
    gives packages their stamps by path: each entry must
    name exactly one package and give a value that is a stamp. [imports]
    gives each package's import keys (docs/design/separate-compilation.md
    C6, C10). *)
val assemble :
  ?buffers:(string * string) list ->
  ?root:bool ->
  ?imports:(string * string * string) list ->
  ?stamps:(string * string) list ->
  Tst.Assembly.request list ->
  (Tst.Assembly.package list, failure) result

(** Each package's C compiled for [target], or for the host when [target]
    is absent: the package's `c.coda` is read, and its C sources are
    compiled by the linked clang (docs/design/ffi.md §1). *)
val c_code : ?target:string -> Tst.Assembly.package list -> (Foreign.package list, failure) result

(** Writes the compilation database of the C sources of the packages
    without a stamp, in the format of `compile_commands.json`, to the given
    file (docs/design/ffi.md F2). *)
val compile_commands : ?target:string -> Tst.Assembly.package list -> string -> (unit, failure) result

(** Semantics, which returns no tree when it finds a problem. *)
val check : ?c:Foreign.package list -> Tst.Assembly.package list -> (Tst.Nodes.Program.t, failure) result

(** Semantics as the language server runs it: the tree, whatever problems
    it has, with every problem and the index of every name the check
    resolved. [placeholder] is the identifier a completion wrote at the
    cursor (docs/design/language-server.md). *)
type analysis = {
  program : Tst.Nodes.Program.t;
  diagnostics : Diagnostic.t list;
  index : Tst.Index.t Lazy.t;
}

val analyze : ?c:Foreign.package list -> ?placeholder:string -> Tst.Assembly.package list -> analysis

(** Checks that the root declares a `main`. This is the only check for
    `main`; lowering assumes it. *)
val require_main : Tst.Nodes.Program.t -> (unit, failure) result

(** Checks that a build with [root], as `--root` or `--no-root` sets it, may
    be built into an executable: a build without a root may not. *)
val buildable : bool option -> (unit, failure) result

(** The size in bytes of the range each context reserves for its frames:
    the main context's, from `--fixed-region`, and each spawned call's, from
    `--spawned-fixed-region`. [None] takes the default. *)
type regions = Build_flags.regions = { fixed : int option; spawned : int option }

(** Stage 4, with the bodies of stamped dependencies' functions taken in
    for LLVM to inline. Without [root], lowering starts from every function
    the build declares rather than from the root's `main`. A type that the
    main context's range in [regions] could not hold is refused where the
    type is named.
    With [compare_glue], every thunk of a stamped dependency's glue is
    lowered too, for [c_modules] to write that glue again and compare it
    with its release's (docs/design/ffi.md F13). A library given
    [program_write_backs], the file [write_backs] wrote for a program, is
    lowered for that program alone (docs/design/lowering.md §9,
    "Snapshots"). *)
val lower :
  ?regions:regions ->
  ?compare_glue:bool ->
  ?program_write_backs:string ->
  root:bool ->
  Tst.Assembly.package list ->
  Tst.Nodes.Program.t ->
  (Cgt.Nodes.Program.t, failure) result

(** Writes the places the program writes back into to [output], as the file
    that a library built for this program alone reads (`--write-backs`). *)
val write_backs : Tst.Assembly.package list -> Tst.Nodes.Program.t -> output:string -> (unit, failure) result

(** The C code each unstamped package of the build compiles into this
    object, with the glue for the thunks the tree's foreign calls go through
    (docs/design/ffi.md F8, F9), for [target], or for the host when
    [target] is absent. [c] is the result of [c_code] for the packages. A
    build without [root] builds a library, whose C globals are renamed for
    fetching to stamp. A stamped dependency's archives are renamed after
    the C names that [link]'s objects define with the dependency's prefix
    (docs/design/ffi.md F15). The modules of the dependency's C whose hashes
    match [hashes], the rows its release published, are retained for an
    optimized build to inline (F13). *)
val c_modules :
  ?target:string ->
  ?link:string list ->
  ?hashes:Foreign.Hashes.row list ->
  root:bool ->
  Tst.Assembly.package list ->
  Foreign.package list ->
  Cgt.Nodes.Program.t ->
  (Codegen.c_package list, failure) result

(** Every call marked `comptime` evaluated and its value written in its
    place, which every build does before stage 5 (docs/design/comptime.md).
    Inside such a call the runtime's `arguments` gives [arguments], the
    arguments the build was started with, and a call into C runs [c], as in
    [optimize]. The boolean beside the program is true when some marked
    call read the runtime's `arguments`; `--object` records that with
    [write_arguments_marker]. A call that cannot be evaluated is a
    diagnostic pointing into [packages]' sources. *)
val comptime :
  ?target:string ->
  ?c:Codegen.c_package list ->
  arguments:string list ->
  Tst.Assembly.package list ->
  Cgt.Nodes.Program.t ->
  (Cgt.Nodes.Program.t * bool, failure) result

(** Stage 5 when [optimize] is true; otherwise the tree unchanged. A call
    into C is folded by running [c], the packages' C code for [target]
    (docs/design/ffi.md F16). *)
val optimize :
  ?target:string ->
  ?c:Codegen.c_package list ->
  optimize:bool ->
  Cgt.Nodes.Program.t ->
  (Cgt.Nodes.Program.t, failure) result

(** The LLVM module's text. Each of these functions builds for [target], or
    for the host when [target] is absent, and with [pack] passes small
    aggregates as packed words
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

(** The rows of the C module hash files in [paths] (Foreign.Hashes), which
    `--c-hashes` gives. *)
val read_hashes : string list -> (Foreign.Hashes.row list, failure) result

(** The hash rows for those packages of [c] (as [c_code] made them) that
    the object holds, taken from the packages [c_modules] returned. `--object`
    writes these rows beside the object (docs/design/ffi.md F15). *)
val hashes_of : Tst.Assembly.package list -> Foreign.package list -> Codegen.c_package list -> Foreign.Hashes.row list

(** Writes [rows] beside the object [output] as `STEM.c.hashes`, after
    removing any such file an earlier build wrote there. No file is written
    when [rows] is empty. *)
val write_hashes : output:string -> Foreign.Hashes.row list -> (unit, failure) result

(** Writes an empty `STEM.arguments` beside the object [output] when [read]
    is true, after removing any such file an earlier build wrote there. The
    file marks an object whose `comptime` calls read the runtime's
    `arguments` (docs/design/comptime.md), so a package manager that caches
    the object keys it on the build's arguments as well. *)
val write_arguments_marker : output:string -> read:bool -> (unit, failure) result

(** A usage error when [output] ends in `.arguments`, so that the object
    would be the path of its own marker; otherwise nothing. `--object`
    checks [output] before it builds anything. *)
val check_object_output : string -> (unit, failure) result

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

(** Compiles the runtime for the target into a released toolchain's
    directory of runtimes (`--bundle-runtime`, docs/design/lowering.md
    §7). *)
val bundle_runtime : target:string -> optimize:bool -> string -> (unit, failure) result

(** A temporary file name beside the output, drawn from the random source:
    the contents are written under this name first. *)
val temporary_name : Random.State.t -> string -> string

(** [rewrite_object ~stamps ~rewrite ~input ~output] writes [output] as
    [rewrite] makes it from [input]'s contents, after checking that each of
    [stamps] is a stamp and, when there are two, that both are versions of one
    package (`--rewrite` and `--remap`, docs/design/separate-compilation.md
    C9, C11). The object is written beside [output] under a name drawn from
    [random] and renamed into place, so a failure leaves an existing [output]
    unchanged. A drawn name that is already taken is left alone and another
    name is drawn, up to eight names in all. *)
val rewrite_object :
  random:Random.State.t ->
  stamps:string list ->
  rewrite:(string -> (string * 'a, string) result) ->
  input:string ->
  output:string ->
  (unit, failure) result

(** The flags of a package build, which `zanec` and the language server
    read alike. *)
module Build_flags = Build_flags
