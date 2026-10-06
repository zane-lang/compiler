(** The pipeline as a front end runs it (docs/design/stages.md): each step a
    result whose failure is every problem it found, with the text of the
    files they point into. *)

type failure = { diagnostics : Diagnostic.t list; sources : Source.Files.t }

(** A failure of [diagnostics], pointing into [sources]. *)
val fail : ?sources:Source.Files.t -> Diagnostic.t list -> ('a, failure) result

(** Each diagnostic as a person reads it, in order. *)
val render : failure -> string list

(** What the root package is (packages.md §6.2): an application has a
    `main` to start from, and a library does not become an executable. *)
type kind = Application | Library

(** The packages of the build, the first the root unless [root] is false,
    as in a library build, which has none (packages.md §6.1). [stamps]
    gives a package its stamp by path, and must name exactly one package
    each; [imports] gives each package's import keys
    (docs/design/separate-compilation.md C6, C10). *)
val assemble :
  ?root:bool ->
  ?imports:(string * string * string) list ->
  ?stamps:(string * string) list ->
  Tst.Assembly.request list ->
  (Tst.Assembly.package list, failure) result

(** Semantics, which gives no tree when it found a problem. *)
val check : Tst.Assembly.package list -> (Tst.Nodes.Program.t, failure) result

(** That the root declares a `main`: the one check for it, which lowering
    takes as given. *)
val require_main : Tst.Nodes.Program.t -> (unit, failure) result

(** That a root of this kind may be built into an executable. *)
val buildable : kind option -> (unit, failure) result

val lower :
  kind:kind -> Tst.Assembly.package list -> Tst.Nodes.Program.t -> (Cgt.Nodes.Program.t, failure) result

(** Stage 5 when [optimize], and the tree as it is otherwise. *)
val optimize : optimize:bool -> Cgt.Nodes.Program.t -> Cgt.Nodes.Program.t

(** The LLVM module's text. *)
val ir : ?target:string -> optimize:bool -> Cgt.Nodes.Program.t -> (string, failure) result

val executable :
  ?target:string ->
  optimize:bool ->
  link:string list ->
  Cgt.Nodes.Program.t ->
  string ->
  (unit, failure) result

val object_file :
  ?target:string -> optimize:bool -> Cgt.Nodes.Program.t -> string -> (unit, failure) result
