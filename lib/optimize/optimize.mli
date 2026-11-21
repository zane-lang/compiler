(** Stage 5: optimization, the CGT to a faster CGT
    (docs/design/optimization.md). An unoptimized build runs none of it. *)

(** The program with every value it can compute at compile time computed.
    A call into C runs on [c], the program's C modules, the retained ones of
    stamped dependencies among them (docs/design/ffi.md F16); with none, no
    call into C folds. The modules must live while [run] does. *)
val run : ?c:Llvm.llmodule list -> Cgt.Nodes.Program.t -> Cgt.Nodes.Program.t

(** Every call marked `comptime` evaluated, and its value written in place
    of the call (docs/design/comptime.md). Every build runs it, before
    [run]. [arguments] is what the runtime's `arguments` gives inside such
    a call: the arguments the build was started with. A call into C runs on
    [c], as for [run]. A call that cannot be evaluated, or that writes
    capability-backed state, is a diagnostic naming it. *)
val comptime :
  ?c:Llvm.llmodule list ->
  arguments:string list ->
  Cgt.Nodes.Program.t ->
  (Cgt.Nodes.Program.t, Diagnostic.t list) result
