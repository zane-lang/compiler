(* What each function of the runtime is to a fold (docs/design/optimization.md
   O3). Every intrinsic reaches the CGT either as ordinary nodes -- an
   operator as a [Binary], `branch` as an [If] -- or as a call into the
   runtime, so this match over [Cgt.Runtime.fn] is the whole list. It is
   exhaustive on purpose: a function added to the runtime does not compile
   until it says which class it is in.

   [Computed] runs at compile time. [Output] runs too, and what it did is
   replayed where the folded code was. [Input] gives a value only the
   running program has, such as its arguments, and stops a fold. *)

type t = Computed | Output | Input

let classify : Cgt.Runtime.fn -> t = function
  | Print | Set_threads | Set_threads_auto -> Output
  | Arguments -> Input
  (* A handle's stamp is the next of a counter the running program keeps:
     a fold that makes one in a call into C keeps its own
     (docs/design/ffi.md F18). A null handle stops the program. *)
  | Handle_made -> Computed
  | No_object -> Input
  (* Whether the thread has a context is a fact of the running program,
     and only a call from C, which no fold makes, runs either. *)
  | Callback_attach | Callback_detach -> Input
  | Text_join | Text_equal | Text_i32 | Text_i64 | Text_f32 | Text_f64
  | List_new | List_push | List_at | List_remove _ | List_swap_remove _ | Array_at | Constant_begin
  | Constant_end | Writeback
  | Parse_i64 | Parse_f64 ->
      Computed
  (* Codegen calls these for nodes of the tree rather than the tree naming
     them: a scope, a held slot, a copy, a box, a spawn, a run of pushes, and
     the walks it emits for each type. The evaluator gives each node its
     meaning directly. *)
  | List_reserve | Scope_enter | Scope_drain | Hold | Too_deep | Promote | Arrive | Copy
  | Overwrite | Box | Spawn | Join | Snapshot | Out_of_range
  | Region_at | Alloc | Alloc_held | Free | Leaves | Defer | Defer_return
  | Overwrite_handles | Overwrite_settled | Handle_end | Handle_set ->
      Computed

(* What a math function of `@math$` on operands of type [t] is to a fold.
   An exact one is [Computed]. An approximate one is [Input]: its result is
   the C math library's where the program runs (math.md §2.6), which the
   compiler's own may not match. So is an [F32] `fma`, which a double would
   compute rounded twice. *)
let math (fn : Cgt.Math.fn) (t : Cgt.Nodes.Ty.t) =
  match (fn, t) with
  | Cgt.Math.Fma, Cgt.Nodes.Ty.F32 -> Input
  | _ when Cgt.Math.exact fn -> Computed
  | _ -> Input
