(* What the CGT says about a loop before it is emitted: whether it is
   emitted twice ([versioned]) and whether it is asked to be unrolled twice
   ([unrolled]). [Emit] includes this module. *)
open Cgt.Nodes
open Loop_shapes

(* Whether an approximate math function of `@math$` is a call to the C math
   library rather than an instruction ([Emit.math]). *)
let library_math = function
  | Cgt.Math.Cbrt | Cgt.Math.Sin | Cgt.Math.Cos | Cgt.Math.Tan | Cgt.Math.Asin | Cgt.Math.Acos | Cgt.Math.Atan
  | Cgt.Math.Atan2 | Cgt.Math.Exp | Cgt.Math.Log | Cgt.Math.Pow | Cgt.Math.Hypot ->
      true
  | _ -> false

(* The count from which a [versioned] loop runs its long copy, and how often
   each copy is said to go round: the long one as a hot loop, the short one
   too few times for IRCE to expect its split to pay. *)
let long_loop = 16
let long_trips = 1000
let short_trips = 4

(* Whether a loop with [body] can leave before its count runs out: it
   returns, or leaves a block that holds it. *)
let leaves_early = Cgt.Traverse.leaves

(* Whether [e] reads or writes a list's or an array's element, whose
   check IRCE may take out of a loop. *)
let indexes (e : Expr.t) =
  match e.Expr.node with
  | Expr.Runtime { fn = Cgt.Runtime.List_at | Cgt.Runtime.Array_at; _ } -> true
  | _ -> false

(* Whether a loop with [body] in the function [symbol] is emitted twice
   (Stat.Repeat): it holds no loop, no spawned call and no call back into
   [symbol], whose cost would dwarf a check, nothing leaves it before its
   count runs out, and it reads or writes a list's element, whose check IRCE
   may take out of it. *)
(* EXPERIMENT (LangArena zane-vs-c, R8): with ZANE_VERSION_CALLS=0 a loop
   that calls any function is emitted once. Its two copies would give the
   callee two call sites, and LLVM's inliner, which gives a function with
   one caller a large bonus, then leaves a mid-sized callee out of line in
   both (Brainfuck's `command`: cost 315 against a threshold of 225). *)
let calls_stay_single () = Sys.getenv_opt "ZANE_VERSION_CALLS" = Some "0"

(* EXPERIMENT: how many call sites each function has in the program being
   emitted ([count_call_sites]). With ZANE_VERSION_CALLS=1, only a loop
   that calls a function with one call site is emitted once: two copies
   would cost LLVM's single-caller inline bonus there, while a callee with
   other callers has none to lose. *)
let call_sites : (string, int) Hashtbl.t = Hashtbl.create 64

let count_call_sites (funcs : Func.t list) =
  Hashtbl.reset call_sites;
  List.iter
    (fun (f : Func.t) ->
      Cgt.Traverse.walk_stats
        (fun e ->
          match e.Expr.node with
          | Expr.Call { fn; _ } -> Hashtbl.replace call_sites fn (1 + Option.value ~default:0 (Hashtbl.find_opt call_sites fn))
          | _ -> ())
        (fun _ -> ())
        f.Func.body)
    funcs

let single_caller fn =
  Sys.getenv_opt "ZANE_VERSION_CALLS" = Some "1" && Hashtbl.find_opt call_sites fn = Some 1

let versioned ~symbol body =
  (not (leaves_early body))
  && (not
        (Cgt.Traverse.exists_in body
           ~expr:(fun e ->
             match e.Expr.node with Expr.Call { fn; _ } -> fn = symbol || calls_stay_single () || single_caller fn | _ -> false)
           ~stat:(function Stat.Repeat _ | Stat.Spawn _ | Stat.Join _ -> true | _ -> false)))
  && Cgt.Traverse.exists_in body
       ~expr:indexes ~stat:(fun _ -> false)

(* Whether a counted loop with [body] is asked to be unrolled twice
   (Stat.Repeat): it can leave before its count runs out, holds no loop,
   spawn or join, and calls nothing: no function, by name, through a value
   or in C, and none of the runtime's functions. An element's index check
   counts as no call, since codegen emits it in line as a compare and an
   address, and its failure stops the program; every other runtime
   operation is a call into the runtime, which the optimized passes inline
   only sometimes. The same goes for an approximate math function, a C
   library call ([library_math]); for a box, which allocates; for a
   snapshot, an overwrite and a value taken out of an arena, which the
   runtime makes; for a scope that opens a region ([Loop_shapes.light],
   which leaves out only that a frame of more than 4 KiB opens one too);
   and for a copy, a hold, a reservation or a placement of a value whose
   layout lists anything ([listed]), whose blocks the runtime copies,
   lists or settles. Every build marks it; only the optimized passes and
   tier 1's act on the mark. LLVM 21's `-O2` leaves such a loop
   rolled on x86-64 even when its body is a dozen arithmetic operations,
   since the target's cost model allows partial unrolling only of smaller
   loops, and in a copy whose two exits lead to the same place the passes
   merge the exit tests, after which its trips cannot be counted at all.
   Asked for two, it unrolls a short loop of arithmetic such as `floats`'
   escape test. A loop that calls is left alone:
   its call dwarfs the test unrolling saves, and the loop the memo pass
   checks, which calls, is 2.5% slower in `depths` unrolled
   (docs/design/lowering.md, "The passes"). *)
let unrolled ~listed body =
  let calls (e : Expr.t) =
    match e.Expr.node with
    | Expr.Call _ | Expr.Call_value _ | Expr.Foreign_call _ | Expr.Box _ | Expr.Snapshot _ | Expr.Escape _ -> true
    | Expr.Runtime { fn = Cgt.Runtime.List_at | Cgt.Runtime.Array_at | Cgt.Runtime.Out_of_range; _ } -> false
    | Expr.Runtime _ -> true
    | Expr.Math { fn; _ } -> library_math fn
    | Expr.Take { layout; _ } | Expr.Copy { layout; _ } -> listed layout
    | _ -> false
  in
  let stops = function
    | Stat.Repeat _ | Stat.Spawn _ | Stat.Join _ | Stat.Overwrite _ -> true
    | Stat.Scope { id; body } -> not (light id body)
    | Stat.Hold { layout; _ } | Stat.Reserve { layout; _ } | Stat.Place { layout; _ } -> listed layout
    | _ -> false
  in
  leaves_early body && not (Cgt.Traverse.exists_in body ~expr:calls ~stat:stops)
