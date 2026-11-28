(* The C runtime's functions that emitted code calls (docs/design/lowering.md
   L17), as runtime/zane.h declares them. A call names a runtime function by
   this variant, so a misspelled function is a compile error, and the unit tests check
   every [signature] against the prototype in zane.h, so the two
   declarations cannot drift apart. [Region_at] to [Defer_return], and
   [Handle_end] and [Handle_set], are called only by the walks codegen
   emits for each type (lib/codegen/walks.ml). [Callback_attach] and
   [Callback_detach] are called only by a lambda's adapter, on a thread
   without a context (docs/design/ffi.md F11). A removal records
   whether the list's elements are scalars only, with no handle among their
   bytes (Ty.holds_handle): codegen makes the removal in line, and its tag for
   the elements it moves depends on that flag (Emit.remove). *)

type fn =
  | Print
  | Text_join
  | Text_expect
  | Text_taken
  | Text_equal
  | Text_i32
  | Text_i64
  | Text_f32
  | Text_f64
  (* A String made from a List<U8>'s bytes (generics.md §8.6). *)
  | Text_bytes
  (* A range of a list's elements
     copied onto the end of a list. *)
  | List_append
  (* A range of a list's elements
     copied over a range of a list. *)
  | List_copy
  | List_same
  | List_hash
  (* A list of integers sorted in place. *)
  | List_sort
  (* A list of indices sorted
     stably by the keys they name. *)
  | List_sort_by
  (* A byte set for [Text_find_any] and [Text_find_pair]. *)
  | Byte_set
  (* `findPair` and `findAny` over a string's bytes. *)
  | Text_find_pair
  | Text_find_any
  | Text_hash
  | Scope_enter
  | Hold
  | Too_deep
  | Promote
  | Arrive
  | Copy
  | Overwrite
  | Box
  | List_new
  | List_push
  | List_reserve
  | List_room
  | List_at
  | List_remove of { scalars : bool }
  | List_swap_remove of { scalars : bool }
  | Array_at
  | Out_of_range
  | Main_aborted
  (* Experimental (docs/design/interleaving.md): a hint that the element at
     an index of a list will be read soon, made only when the index is
     inside the list. Emit makes the hint in line; there is no runtime
     function. *)
  | Prefetch
  | Scope_drain
  | Spawn
  | Join
  | Set_threads
  | Set_threads_auto
  (* A `@controlflow$register` on a timer (control-flow.md §4.1):
     [Tick_start] gives the first deadline from the interval, and [Tick]
     waits from one step to the next until the deadline, giving the next. *)
  | Tick_start
  | Tick
  | Snapshot
  | Constant_begin
  | Constant_end
  | Writeback
  | Arguments
  (* The monotonic clock, in nanoseconds (`@runtime$monotonicNanoseconds`). *)
  | Monotonic_ns
  | Parse_i64
  | Parse_f64
  | Parse_f64_at
  | Region_at
  | Alloc
  | Alloc_held
  (* A moved list's or string's block past a chunk, with its growable span
     handed over to the new region when the block has one
     (runtime/arena.c). *)
  | Relocate
  (* A box's payload (runtime/arena.c, `zane_box_held`), held and checked. *)
  | Box_held
  | Box_in
  | Free
  | Leaves
  | Defer
  | Defer_return
  (* Experimental pooled variants (runtime/list.c). *)
  | Pool_new
  | Pool_push
  | Pool_append
  | Pool_root
  | Pool_copy
  | Link
  | Pool_reserve
  | Pool_new_unbounded
  | Overwrite_handles
  | Overwrite_settled
  | Handle_made
  | No_object
  | Handle_end
  | Handle_set
  | Callback_attach
  | Callback_detach
  (* A C-held object's top-level scope (packages.md §8.5, runtime/held.c):
     made for an owner an exported lambda returns, the owner's blocks
     settled in it, a value a `this T mut` subject's lambda returns kept
     in it for C's views, those values ended as the next such call begins,
     and the scope drained once a lambda that takes the owner has run. *)
  | C_held_new
  | C_held_settle
  | C_held_lend
  | C_held_renew
  | C_held_end
  (* A spawned call's subject into a region of its own (runtime/spawn.c). *)
  | Island
  (* A worker pool's runtime (concurrency.md §6, runtime/workers.c): a new
     pool, a worker started, an event published, and the reads of the state
     and of the elements. *)
  | Workers_new
  | Workers_start
  | Workers_publish
  | Workers_state
  | Workers_elements

let all = [ Print; Text_join; Text_expect; Text_taken; Text_equal; Text_i32; Text_i64; Text_f32; Text_f64; Text_bytes; List_append; List_copy; List_same; List_hash; List_sort; List_sort_by; Byte_set; Text_find_pair; Text_find_any; Text_hash; Scope_enter; Hold; Too_deep; Promote; Arrive; Copy; Overwrite; Box; List_new; List_push; List_reserve; List_room; List_at; List_remove { scalars = false }; List_swap_remove { scalars = false }; Array_at; Out_of_range; Main_aborted; Scope_drain; Spawn; Join; Set_threads; Set_threads_auto; Tick_start; Tick; Snapshot; Constant_begin; Constant_end; Writeback; Arguments; Monotonic_ns; Parse_i64; Parse_f64; Parse_f64_at; Region_at; Alloc; Alloc_held; Relocate; Box_held; Box_in; Free; Leaves; Defer; Defer_return; Pool_new; Pool_push; Pool_append; Pool_root; Pool_copy; Link; Pool_reserve; Pool_new_unbounded; Overwrite_handles; Overwrite_settled; Handle_made; No_object; Handle_end; Handle_set; Callback_attach; Callback_detach; C_held_new; C_held_settle; C_held_lend; C_held_renew; C_held_end; Island; Workers_new; Workers_start; Workers_publish; Workers_state; Workers_elements ]

let name = function
  | Print -> "zane_print"
  | Text_join -> "zane_text_join"
  | Text_expect -> "zane_text_expect"
  | Text_taken -> "zane_text_taken"
  | Text_equal -> "zane_text_equal"
  | Text_i32 -> "zane_text_i32"
  | Text_i64 -> "zane_text_i64"
  | Text_f32 -> "zane_text_f32"
  | Text_f64 -> "zane_text_f64"
  | Text_bytes -> "zane_text_bytes"
  | List_append -> "zane_list_append"
  | List_copy -> "zane_list_copy"
  | List_same -> "zane_list_same"
  | List_hash -> "zane_list_hash"
  | List_sort -> "zane_list_sort"
  | List_sort_by -> "zane_list_sort_by"
  | Byte_set -> "zane_byte_set"
  | Text_find_pair -> "zane_text_find_pair"
  | Text_find_any -> "zane_text_find_any"
  | Text_hash -> "zane_text_hash"
  | Scope_enter -> "zane_scope_enter"
  | Hold -> "zane_hold"
  | Too_deep -> "zane_too_deep"
  | Promote -> "zane_promote"
  | Arrive -> "zane_arrive"
  | Copy -> "zane_copy"
  | Overwrite -> "zane_overwrite"
  | Box -> "zane_box"
  | List_new -> "zane_list_new"
  | List_push -> "zane_list_push"
  | List_reserve -> "zane_list_reserve"
  | List_room -> "zane_list_room"
  | List_at -> "zane_list_at"
  | List_remove _ -> "zane_list_remove"
  | List_swap_remove _ -> "zane_list_swap_remove"
  | Array_at -> "zane_array_at"
  | Out_of_range -> "zane_out_of_range"
  | Main_aborted -> "zane_main_aborted"
  | Prefetch -> "zane_prefetch"
  | Scope_drain -> "zane_scope_drain"
  | Spawn -> "zane_spawn"
  | Join -> "zane_join"
  | Set_threads -> "zane_set_threads"
  | Set_threads_auto -> "zane_set_threads_auto"
  | Tick_start -> "zane_tick_start"
  | Tick -> "zane_tick"
  | Snapshot -> "zane_snapshot"
  | Constant_begin -> "zane_constant_begin"
  | Constant_end -> "zane_constant_end"
  | Writeback -> "zane_writeback"
  | Arguments -> "zane_arguments"
  | Monotonic_ns -> "zane_monotonic_ns"
  | Parse_i64 -> "zane_parse_i64"
  | Parse_f64 -> "zane_parse_f64"
  | Parse_f64_at -> "zane_parse_f64_at"
  | Region_at -> "zane_region_at"
  | Alloc -> "zane_alloc"
  | Alloc_held -> "zane_alloc_held"
  | Relocate -> "zane_relocate"
  | Box_held -> "zane_box_held"
  | Box_in -> "zane_box_in"
  | Free -> "zane_free"
  | Leaves -> "zane_leaves"
  | Defer -> "zane_defer"
  | Defer_return -> "zane_defer_return"
  | Pool_new -> "zane_pool_new"
  | Pool_push -> "zane_pool_push"
  | Pool_append -> "zane_pool_append"
  | Pool_root -> "zane_pool_root"
  | Pool_copy -> "zane_pool_copy"
  | Link -> "zane_link"
  | Pool_reserve -> "zane_pool_reserve"
  | Pool_new_unbounded -> "zane_pool_new_unbounded"
  | Overwrite_handles -> "zane_overwrite_handles"
  | Overwrite_settled -> "zane_overwrite_settled"
  | Handle_made -> "zane_handle_made"
  | No_object -> "zane_no_object"
  | Handle_end -> "zane_handle_end"
  | Handle_set -> "zane_handle_set"
  | Callback_attach -> "zane_callback_attach"
  | C_held_new -> "zane_c_held_new"
  | C_held_settle -> "zane_c_held_settle"
  | C_held_lend -> "zane_c_held_lend"
  | C_held_renew -> "zane_c_held_renew"
  | C_held_end -> "zane_c_held_end"
  | Callback_detach -> "zane_callback_detach"
  | Island -> "zane_island_make"
  | Workers_new -> "zane_workers_new"
  | Workers_start -> "zane_workers_start"
  | Workers_publish -> "zane_workers_publish"
  | Workers_state -> "zane_workers_state"
  | Workers_elements -> "zane_workers_elements"

(* A worker pool's free thunk (runtime/workers.c), which a pool's handle is
   ended through as a foreign handle is through its glue's. *)
let workers_free = "zane_workers_free"

(* A value as the C ABI passes it: [I32] a `uint32_t`, [I64] an `int64_t`,
   and [Ptr] any pointer, a function's included. *)
type ty = Void | I32 | I64 | F32 | F64 | Ptr

(* The return type, then the parameters. *)
let signature = function
  | Print -> (Void, [ Ptr ])
  | Text_join -> (Void, [ Ptr; Ptr; Ptr ])
  | Text_expect -> (I64, [])
  | Text_taken -> (Void, [ Ptr; Ptr; I64 ])
  | Text_equal -> (I64, [ Ptr; Ptr ])
  | Text_i32 -> (Void, [ Ptr; I32 ])
  | Text_i64 -> (Void, [ Ptr; I64 ])
  | Text_f32 -> (Void, [ Ptr; F32 ])
  | Text_f64 -> (Void, [ Ptr; F64 ])
  | Text_bytes -> (Void, [ Ptr; Ptr ])
  | List_append -> (Void, [ Ptr; Ptr; I64; I64; I64 ])
  | List_copy -> (Void, [ Ptr; I64; Ptr; I64; I64; I64 ])
  | List_same -> (I64, [ Ptr; I64; Ptr; I64; I64; I64 ])
  | List_hash -> (I64, [ Ptr; I64; I64; I64 ])
  | List_sort -> (Void, [ Ptr; I64 ])
  | List_sort_by -> (Void, [ Ptr; Ptr ])
  | Byte_set -> (Void, [ Ptr; Ptr ])
  | Text_find_pair -> (I64, [ Ptr; I64; I64; Ptr; I64; Ptr ])
  | Text_find_any -> (I64, [ Ptr; I64; I64; Ptr ])
  | Text_hash -> (I64, [ Ptr ])
  | Scope_enter -> (Ptr, [ I64 ])
  | Hold -> (Void, [ Ptr; Ptr ])
  | Too_deep -> (Void, [  ])
  | Promote -> (Void, [ Ptr; Ptr; Ptr ])
  | Arrive -> (Void, [ Ptr; Ptr ])
  | Copy -> (Void, [ Ptr; Ptr ])
  | Overwrite -> (Void, [ Ptr; Ptr; I64; Ptr ])
  | Box -> (Ptr, [ I64; I64 ])
  | List_new -> (Void, [ Ptr ])
  | List_push -> (Ptr, [ Ptr; I64 ])
  | List_reserve -> (Ptr, [ Ptr; I64; I64 ])
  | List_room -> (Void, [ Ptr; I64; I64 ])
  | List_at -> (Ptr, [ Ptr; I64; I64 ])
  | List_remove _ -> (Void, [ Ptr; I64; I64 ])
  | List_swap_remove _ -> (Void, [ Ptr; I64; I64 ])
  | Array_at -> (Ptr, [ Ptr; I64; I64; I64 ])
  | Out_of_range -> (Void, [  ])
  | Main_aborted -> (Void, [ Ptr ])
  | Prefetch -> (Void, [ Ptr; I64; I64 ])
  | Scope_drain -> (Void, [ Ptr ])
  | Spawn -> (Void, [ Ptr; Ptr; Ptr; Ptr; I64 ])
  | Join -> (Void, [ Ptr ])
  | Set_threads -> (I64, [ I64 ])
  | Set_threads_auto -> (Void, [  ])
  | Tick_start -> (I64, [ I64 ])
  | Tick -> (I64, [ I64; I64 ])
  | Snapshot -> (Void, [ Ptr; Ptr; I64 ])
  | Constant_begin -> (I64, [ Ptr ])
  | Constant_end -> (Void, [ Ptr; Ptr; Ptr ])
  | Writeback -> (Void, [ Ptr; Ptr; I64; Ptr ])
  | Arguments -> (Void, [ Ptr ])
  | Monotonic_ns -> (I64, [])
  | Parse_i64 -> (I64, [ Ptr; Ptr ])
  | Parse_f64 -> (I64, [ Ptr; Ptr ])
  | Parse_f64_at -> (I64, [ Ptr; Ptr; I64; I64 ])
  | Region_at -> (Ptr, [ Ptr ])
  | Alloc -> (Ptr, [ Ptr; I64; I64 ])
  | Alloc_held | Box_held | Box_in -> (Ptr, [ Ptr; I64; I64 ])
  | Relocate -> (Ptr, [ Ptr; Ptr; I64; I64; I64 ])
  | Free -> (Void, [ Ptr; I64; I64 ])
  | Leaves -> (I64, [ Ptr; Ptr; I64 ])
  | Defer -> (Void, [ Ptr; Ptr; Ptr; Ptr; I64 ])
  | Defer_return -> (Void, [ Ptr; Ptr; I64; I64 ])
  | Pool_new -> (Void, [ Ptr ])
  | Pool_push -> (I64, [ Ptr; Ptr; I64; I64; I64; I64; I64; I64; I64; I64; I64; I64 ])
  | Pool_append -> (I64, [ Ptr; Ptr; I64 ])
  | Pool_root -> (Ptr, [ Ptr; I64 ])
  | Pool_copy -> (Void, [ Ptr; Ptr; I64; I64; I64; I64; I64 ])
  | Link -> (Ptr, [ Ptr ])
  | Pool_reserve -> (Void, [ Ptr; I64 ])
  | Pool_new_unbounded -> (Void, [ Ptr ])
  | Overwrite_handles | Overwrite_settled -> (Void, [ Ptr; Ptr; I64; Ptr ])
  | Handle_made -> (I64, [ Ptr ])
  | No_object -> (Void, [  ])
  | Handle_end -> (Void, [ Ptr; Ptr ])
  | Handle_set -> (Void, [ Ptr; Ptr; Ptr ])
  | Callback_attach | Callback_detach -> (Void, [])
  | C_held_new -> (Ptr, [ I64; I64 ])
  | C_held_settle -> (Void, [ Ptr; Ptr ])
  | C_held_lend -> (Void, [ Ptr; Ptr; I64; Ptr ])
  | C_held_renew | C_held_end -> (Void, [ Ptr ])
  | Island -> (Void, [ Ptr; I64; Ptr; I64 ])
  | Workers_new -> (Ptr, [ I64; Ptr; I64; Ptr; Ptr; Ptr; I64; Ptr; I64 ])
  | Workers_start -> (Void, [ Ptr; Ptr; I64; Ptr; Ptr; Ptr; Ptr; Ptr; I64; Ptr ])
  | Workers_publish -> (Void, [ Ptr; I64; I64 ])
  | Workers_state -> (Ptr, [ Ptr ])
  | Workers_elements -> (Void, [ Ptr; Ptr; I64; Ptr ])

(* The size of the range each context reserves for its frames, the main
   context's and each spawned call's, when the root manifest gives no size
   (memory.md §3.1, dependencies.md §2.1). Lowering refuses a type that the
   main context's range could not hold, and codegen writes both sizes into the
   program for the runtime to read. *)
let default_fixed_region = 256 lsl 20
let default_spawned_fixed_region = 8 lsl 20
