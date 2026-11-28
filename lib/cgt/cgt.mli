(** Stage 4: lowering, the TST to the code-generation tree
    (docs/design/lowering.md). *)

module Nodes = Nodes

(** The C runtime's functions that emitted code calls. *)
module Runtime = Runtime

(** The math functions of `@math$`, and which of them are exact. *)
module Math = Math

(** The parts of each node, a walk over every node, and a rewrite, for
    every pass over the tree, and whether statements can end other than
    after their last statement ([leaves]). *)
module Traverse = Traverse

(** The functions whose results are memoized while the program runs, with
    `--memoize`. *)
module Memo = Memo

(** Experimental: whether the compact layout is on: 32-bit references and
    boxes, 16-byte list handles, niche sums and bump regions. *)
module Ref32 = Ref32
module List_pure = List_pure

(** The places a program writes back into, read from the file
    [write_backs] writes (docs/design/lowering.md §9, "Snapshots"). A
    [library] lowered with them, [program_write_backs], is for that program
    alone: its reads of every other place are plain loads. *)
type write_backs

(** The program, lowered from the root package's `main`, from every
    function, lambda constant and handle type of the project's own packages
    when the build is a [library], or from the
    exported lambdas when the root is a [plugin] package, which declares no
    `main` (packages.md §8.1). Every build but a library's also lowers the
    exported lambdas it gives C symbols. A construct that
    lowering does not handle yet is refused with a diagnostic at the
    construct, and so is a type that the main context's range of frames of
    [fixed_region] bytes could not hold ([Runtime.default_fixed_region] when
    absent). [import_bodies] retains
    reachable stamped dependencies' functions with linkage that lets LLVM
    inline them and defines nothing, and [foreign_roots] lowers every thunk
    of a stamped dependency's glue, for a build that writes that glue again
    to compare with its release's (docs/design/ffi.md F13). *)
val lower :
  ?library:bool ->
  ?plugin:bool ->
  ?import_bodies:bool ->
  ?foreign_roots:bool ->
  ?fixed_region:int ->
  ?program_write_backs:write_backs ->
  Tst.Nodes.Program.t ->
  (Nodes.Program.t, Diagnostic.t) result

(** The file of the places the program writes back into. *)
val write_backs : Tst.Nodes.Program.t -> (string, Diagnostic.t) result

(** The places such a file names, or [None] when the text is not such a
    file. *)
val read_write_backs : string -> write_backs option

(** The tree as `zanec --cgt` prints it. *)
val to_node : Nodes.Program.t -> Tree_graph.node
