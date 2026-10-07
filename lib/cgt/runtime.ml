(* The C runtime's functions that emitted code calls (docs/design/lowering.md
   L17), as runtime/zane.h declares them. A call names one by this variant,
   so a misspelled function is a compile error, and the unit tests check
   every [signature] against the prototype in zane.h, so the two
   declarations cannot drift apart. *)

type fn =
  | Print
  | Text_join
  | Text_equal
  | Divide_by_zero
  | Conversion_out_of_range
  | Scope_enter
  | Slot
  | Promote
  | Arrive
  | Vacate
  | Copy
  | Overwrite
  | Box
  | List_new
  | List_push
  | List_at
  | Array_at
  | Scope_drain
  | Frame
  | Spawn
  | Join
  | Set_threads
  | Set_threads_auto
  | Snapshot
  | Constant_begin
  | Constant_end
  | Writeback

let all = [ Print; Text_join; Text_equal; Divide_by_zero; Conversion_out_of_range; Scope_enter; Slot; Promote; Arrive; Vacate; Copy; Overwrite; Box; List_new; List_push; List_at; Array_at; Scope_drain; Frame; Spawn; Join; Set_threads; Set_threads_auto; Snapshot; Constant_begin; Constant_end; Writeback ]

let name = function
  | Print -> "zane_print"
  | Text_join -> "zane_text_join"
  | Text_equal -> "zane_text_equal"
  | Divide_by_zero -> "zane_divide_by_zero"
  | Conversion_out_of_range -> "zane_conversion_out_of_range"
  | Scope_enter -> "zane_scope_enter"
  | Slot -> "zane_slot"
  | Promote -> "zane_promote"
  | Arrive -> "zane_arrive"
  | Vacate -> "zane_vacate"
  | Copy -> "zane_copy"
  | Overwrite -> "zane_overwrite"
  | Box -> "zane_box"
  | List_new -> "zane_list_new"
  | List_push -> "zane_list_push"
  | List_at -> "zane_list_at"
  | Array_at -> "zane_array_at"
  | Scope_drain -> "zane_scope_drain"
  | Frame -> "zane_frame"
  | Spawn -> "zane_spawn"
  | Join -> "zane_join"
  | Set_threads -> "zane_set_threads"
  | Set_threads_auto -> "zane_set_threads_auto"
  | Snapshot -> "zane_snapshot"
  | Constant_begin -> "zane_constant_begin"
  | Constant_end -> "zane_constant_end"
  | Writeback -> "zane_writeback"

(* A value as the C ABI passes it: [I32] a `uint32_t`, [I64] an `int64_t`,
   and [Ptr] any pointer, a function's included. *)
type ty = Void | I32 | I64 | Ptr

(* The return type, then the parameters. *)
let signature = function
  | Print -> (Void, [ Ptr ])
  | Text_join -> (Void, [ Ptr; Ptr; Ptr ])
  | Text_equal -> (I64, [ Ptr; Ptr ])
  | Divide_by_zero -> (Void, [  ])
  | Conversion_out_of_range -> (Void, [  ])
  | Scope_enter -> (I64, [  ])
  | Slot -> (Ptr, [ I64; I64; I64; Ptr ])
  | Promote -> (Void, [ Ptr; Ptr; I64 ])
  | Arrive -> (Void, [ Ptr; Ptr ])
  | Vacate -> (Void, [ Ptr; Ptr ])
  | Copy -> (Void, [ Ptr; Ptr ])
  | Overwrite -> (Void, [ Ptr; Ptr; I64; Ptr ])
  | Box -> (Ptr, [ I64; I64 ])
  | List_new -> (Void, [ Ptr ])
  | List_push -> (Ptr, [ Ptr; I64 ])
  | List_at -> (Ptr, [ Ptr; I64; I64 ])
  | Array_at -> (Ptr, [ Ptr; I64; I64; I64 ])
  | Scope_drain -> (Void, [ I64 ])
  | Frame -> (Ptr, [ I64; I64; I64 ])
  | Spawn -> (Void, [ Ptr; Ptr; Ptr; Ptr; I64 ])
  | Join -> (Void, [ Ptr ])
  | Set_threads -> (I64, [ I64 ])
  | Set_threads_auto -> (Void, [  ])
  | Snapshot -> (Void, [ Ptr; Ptr; I64 ])
  | Constant_begin -> (I64, [ Ptr ])
  | Constant_end -> (Void, [ Ptr; Ptr; Ptr ])
  | Writeback -> (Void, [ Ptr; Ptr; I64; Ptr ])
