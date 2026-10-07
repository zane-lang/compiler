(* What each function of the runtime is to a fold (docs/design/optimization.md
   O3). Every intrinsic reaches the CGT either as ordinary nodes -- an
   operator as a [Binary], `branch` as an [If] -- or as a call into the
   runtime, so this match over [Cgt.Runtime.fn] is the whole list. It is
   exhaustive on purpose: a function added to the runtime does not compile
   until it says which class it is in.

   [Computed] runs at compile time. [Output] runs too, and what it did is
   replayed where the folded code was. [Input] gives a value only the
   running program has, such as a line read from the console or the time,
   and stops a fold. No runtime function is an input yet. *)

type t = Computed | Output | Input

let classify : Cgt.Runtime.fn -> t = function
  | Print | Set_threads | Set_threads_auto -> Output
  | Text_join | Text_equal | List_new | List_push | List_at | Array_at | Constant_begin
  | Constant_end | Writeback ->
      Computed
  (* Codegen calls these for nodes of the tree rather than the tree naming
     them: a division, a conversion, a scope, a slot, a copy, a box, a spawn. The
     evaluator gives each node its meaning directly. *)
  | Divide_by_zero | Conversion_out_of_range | Scope_enter | Scope_drain | Slot | Promote | Arrive | Vacate | Copy
  | Overwrite | Box | Frame | Spawn | Join | Snapshot ->
      Computed
