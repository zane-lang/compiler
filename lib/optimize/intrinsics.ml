(* How a fold treats each function of the runtime (docs/design/optimization.md
   O3). Every intrinsic reaches the CGT either as ordinary nodes -- an
   operator as a [Binary], `branch` as an [If] -- or as a call into the
   runtime, so this match over [Cgt.Runtime.fn] is the whole list. It is
   exhaustive on purpose: a function added to the runtime does not compile
   until this match gives the function's class.

   [Computed] runs at compile time. [Output] runs too, and what it did is
   replayed where the folded code was. [Input] gives a value only the
   running program has, such as its arguments, and stops a fold. *)

type t = Computed | Output | Input

let classify : Cgt.Runtime.fn -> t = function
  | Print | Set_threads | Set_threads_auto -> Output
  | Arguments -> Input
  (* A timer's deadline reads the clock, and what follows a wait runs when
     the running program reaches the wait, a timing no replay could keep,
     so a fold stops at either. *)
  | Tick_start | Tick -> Input
  (* A String from a byte list, which the evaluator does not model. *)
  | Text_bytes -> Input
  (* List range copies, sorts, comparisons, hashes and byte searches, which
     the evaluator does not model. *)
  | List_append | List_copy | List_same | List_hash | List_sort | List_sort_by | Byte_set | Text_find_pair | Text_find_any | Text_hash -> Input
  (* Experimental pooled variants, which the evaluator does not model. *)
  | Pool_new | Pool_push | Pool_append | Pool_root | Pool_copy | Link | Pool_reserve | Pool_new_unbounded -> Input
  (* A handle's stamp is the next of a counter the running program keeps:
     a fold that makes one in a call into C keeps its own
     (docs/design/ffi.md F18). A null handle stops the program. *)
  | Handle_made -> Computed
  | No_object -> Input
  (* An abort of `main` ends the running program, and only the start
     function, which no fold runs, calls it. *)
  | Main_aborted -> Input
  (* Whether the thread has a context is a fact of the running program,
     and only a call from C, which no fold makes, runs either. *)
  | Callback_attach | Callback_detach -> Input
  (* A worker pool's work runs on the running program's threads, beside
     the code after `start`, and a publish is a write the funnel makes
     there, so a fold stops at each (concurrency.md §6.5). *)
  | Workers_new | Workers_start | Workers_publish | Workers_state | Workers_elements -> Input
  | Text_join | Text_expect | Text_taken | Text_equal | Text_i32 | Text_i64 | Text_f32 | Text_f64
  | List_new | List_push | List_at | List_remove _ | List_swap_remove _ | Array_at | Constant_begin
  | Constant_end | Writeback
  | Parse_i64 | Parse_f64 | Parse_f64_at ->
      Computed
  (* Codegen calls these for nodes of the tree rather than the tree naming
     them: a scope, a held slot, a copy, a box, a spawn, a run of pushes, and
     the walks it emits for each type. The evaluator evaluates each such
     node directly. *)
  | List_reserve | List_room | Scope_enter | Scope_drain | Hold | Too_deep | Promote | Arrive | Copy
  | Overwrite | Box | Spawn | Join | Snapshot | Out_of_range | Prefetch | Island
  | Region_at | Alloc | Alloc_held | Relocate | Box_held | Box_in | Free | Leaves | Defer | Defer_return
  | Overwrite_handles | Overwrite_settled | Handle_end | Handle_set ->
      Computed

(* How a fold treats a math function of `@math$` on operands of type [t].
   An exact one is [Computed]. An approximate one is [Input]: its result is
   the C math library's where the program runs (math.md §2.6), which the
   compiler's own may not match. So is an [F32] `fma`, which a double would
   compute rounded twice. *)
let math (fn : Cgt.Math.fn) (t : Cgt.Nodes.Ty.t) =
  match (fn, t) with
  | Cgt.Math.Fma, Cgt.Nodes.Ty.F32 -> Input
  | _ when Cgt.Math.exact fn -> Computed
  | _ -> Input
