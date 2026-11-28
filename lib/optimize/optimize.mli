(** Stage 5: optimization, the CGT to a faster CGT
    (docs/design/optimization.md). An unoptimized build runs none of it. *)

(** The program with every value it can compute at compile time computed.
    A call into C runs on [c], the program's C modules, the retained ones of
    stamped dependencies among them (docs/design/ffi.md F16); with none, no
    call into C folds. The modules must live while [run] does. *)
val run : ?c:Llvm.llmodule list -> Cgt.Nodes.Program.t -> Cgt.Nodes.Program.t

(** Where a call marked `comptime` reads the monotonic clock: the build
    machine's clock ([Live]); that clock, with each reading added to the
    front of the list ([Recorded], tier 0 of a tiered build); or the readings
    the function gives in order, [None] once they are used up ([Replayed],
    tier 1). *)
type clock = Live | Recorded of int64 list ref | Replayed of (unit -> int64 option)

(** Every call marked `comptime` evaluated, and its value written in place
    of the call (docs/design/comptime.md). Every build runs it, before
    [run]. [arguments] is what the runtime's `arguments` gives inside such
    a call: the arguments the build was started with. A call into C runs on
    [c], as for [run]. A call that cannot be evaluated, or that writes
    capability-backed state, is a diagnostic naming it. Such a call reads
    the monotonic clock through [clock], the build machine's own unless
    given (docs/design/tiers.md T12). *)
val comptime :
  ?c:Llvm.llmodule list ->
  ?clock:clock ->
  arguments:string list ->
  Cgt.Nodes.Program.t ->
  (Cgt.Nodes.Program.t, Diagnostic.t list) result
