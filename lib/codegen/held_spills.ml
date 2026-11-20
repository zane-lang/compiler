(* Experimental (docs/experiments/held-allocas, ZANE_HELD_ALLOCAS=1): held
   locals kept off their frames.

   A held local of at most [cap] bytes is emitted as an alloca, so that
   LLVM's SROA can keep it in registers, and keeps its slot in its scope's
   frame for the runtime. The runtime finds the arena a list grows in, or a
   value arrives in, from the address of its slot (runtime/arena.c,
   zane_region_at), and a callee given the address of a place finds it the
   same way, so every call that is given an address in the alloca is given
   the same address in the frame slot instead: the alloca's value is stored
   to the slot before the call and loaded back from it after. Any other use
   of the address (stored as a value, kept by `zane_hold`, merged with
   another pointer, compared or converted) gives up on the alloca: its uses
   take the frame slot, as without the experiment.

   [run] makes these rewrites in a function right after it is emitted,
   before LLVM's passes, while each alloca's uses are all after its hold:
   the frame slot's address, computed at the hold, reaches them all. *)

let on = Sys.getenv_opt "ZANE_HELD_ALLOCAS" = Some "1"

(* The largest held local kept in an alloca: the machine stack is 8 MiB,
   where a context's frames have 256 MiB (docs/design/lowering.md §9). *)
let cap = 256

type held = {
  (* The address of the local's slot in its scope's frame, computed where
     the local is held, and the slot's offset in the frame. *)
  slot : Llvm.llvalue;
  offset : int;
  (* The local's LLVM type, which a store or a load of it whole takes. *)
  ty : Llvm.lltype;
  (* The record of the local's scope, the frame's start. *)
  arena : Llvm.llvalue;
  (* The local's layout, for a checked drain. *)
  layout : Cgt.Nodes.Layout.t;
  (* The stores of the alloca's value to the slot on the checked drains'
     paths, which go if the local takes its slot again. *)
  mutable fills : Llvm.llvalue list;
}

(* Every held alloca of the function being emitted, the latest first.
   LLVM values are found by [==] in lists, never hashed: a hash of one
   follows its address, which would make the order of the rewrites, and so
   the code, differ from one run of the compiler to the next. *)
let order : (Llvm.llvalue * held) list ref = ref []

let record alloca h = order := (alloca, h) :: !order
let find p = Option.map snd (List.find_opt (fun (a, _) -> a == p) !order)

(* The held allocas of the scope whose record is [arena], in the order
   they were held. *)
let of_arena arena = List.rev (List.filter (fun (_, h) -> h.arena == arena) !order)

(* Forgets the function emitted before: [Emit.func] calls this first. *)
let start () = order := []

let callee i =
  if Llvm.instr_opcode i <> Llvm.Opcode.Call then None
  else
    let f = Llvm.operand i (Llvm.num_operands i - 1) in
    if Llvm.classify_value f = Llvm.ValueKind.Function then Some (Llvm.value_name f) else None

let starts p s = String.length s >= String.length p && String.sub s 0 (String.length p) = p

(* Calls given the frame slot for good rather than around the call: one
   that may keep the address past its return (the runtime lists a held slot
   for its drain), and a call to a Zane function, which LLVM may inline, so
   that the copies would go round code that then works on the frame slot,
   or which a loop may make every time round. Only the runtime's calls,
   mostly the slow paths of a push or a growth, are given the slot around
   the call. *)
let keeps = function
  | Some "zane_hold" -> true
  | Some n -> not (starts "zane_" n)
  | None -> true

(* Experimental, within the experiment (ZANE_HELD_LATE=1): a call to a Zane
   function is left given the alloca, which Held_late, after LLVM's passes,
   gives the frame slot if the call is still there. *)
let late = Sys.getenv_opt "ZANE_HELD_LATE" = Some "1"

(* The anchor of a held alloca left to Held_late: a call given the alloca
   and its frame slot, declared to touch only memory nothing else reaches
   and to neither read nor keep either address, so that LLVM's passes keep
   the alloca whole, never splitting it or folding it away, while they
   still read its loads and stores as a local's. Held_late removes it. *)
let anchor_name = "zane_held_anchor"

let anchor m =
  match Llvm.lookup_function anchor_name m with
  | Some f -> f
  | None ->
      let ctx = Llvm.module_context m in
      let ptr = Llvm.pointer_type ctx in
      let f = Llvm.declare_function anchor_name (Llvm.function_type (Llvm.void_type ctx) [| ptr; ptr |]) m in
      let text =
        "declare void @f(ptr readnone captures(none), ptr readnone captures(none)) memory(inaccessiblemem: readwrite) nounwind willreturn"
      in
      let parsed = Llvm_irreader.parse_ir ctx (Llvm.MemoryBuffer.of_string text) in
      let g = Option.get (Llvm.lookup_function "f" parsed) in
      List.iter
        (fun index -> Array.iter (fun a -> Llvm.add_function_attr f a index) (Llvm_extra.function_attrs g index))
        [ Llvm.AttrIndex.Function; Llvm.AttrIndex.Param 0; Llvm.AttrIndex.Param 1 ];
      Llvm.dispose_module parsed;
      f

(* Whether [name] is a Zane function's call, left to Held_late. *)
let left ~after = function
  | Some n -> late && (not after) && (not (starts "zane_" n)) && not (starts "llvm." n)
  | None -> false

(* Intrinsics SROA reads an alloca through. *)
let through = function
  | Some n ->
      starts "llvm.lifetime" n || starts "llvm.memcpy" n || starts "llvm.memmove" n || starts "llvm.memset" n
  | None -> false

type use = Spill of Llvm.llvalue * int * int64 (* a call, its operand, the offset *) | Fine

(* The uses of [p], an address [offset] bytes into the alloca, or [None]
   when one of them gives up on it. *)
let rec uses ?(after = false) ?(every = false) dl p offset acc =
  let uses = uses ~after ~every in
  let result = ref (Some acc) in
  Llvm.iter_uses
    (fun u ->
      match !result with
      | None -> ()
      | Some acc -> (
          let i = Llvm.user u in
          match Llvm.instr_opcode i with
          | Llvm.Opcode.Load -> ()
          | Llvm.Opcode.Store -> if Llvm.operand i 0 == p then result := None
          | Llvm.Opcode.GetElementPtr when Llvm.operand i 0 == p -> (
              match Frame_shadow.gep_offset dl i with
              | Some o -> result := uses dl i (Int64.add offset o) acc
              | None -> result := None)
          | Llvm.Opcode.Call ->
              let name = callee i in
              if through name || left ~after name then ()
              else if name = Some "llvm.assume" || name = Some anchor_name then ()
              else if
                (if every then name = Some "zane_hold" || name = None else keeps name)
                || Llvm.operand i (Llvm.num_operands i - 1) == p
              then result := None
              else begin
                let spills = ref acc in
                for k = 0 to Llvm.num_operands i - 2 do
                  if Llvm.operand i k == p then spills := Spill (i, k, offset) :: !spills
                done;
                result := Some !spills
              end
          | _ -> result := None))
    p;
  !result

let debug = Sys.getenv_opt "ZANE_HELD_ALLOCAS_DEBUG" = Some "1"

(* The first use of [p] that gives up on the alloca, printed. *)
let rec why dl p =
  let found = ref None in
  Llvm.iter_uses
    (fun u ->
      if !found = None then
        let i = Llvm.user u in
        match uses dl i 0L [] with
        | _ when Llvm.instr_opcode i = Llvm.Opcode.GetElementPtr && Llvm.operand i 0 == p ->
            if uses dl i 0L [] = None then found := Some (why dl i)
        | _ -> (
            match uses_one dl p i with true -> () | false -> found := Some (Llvm.string_of_llvalue i)))
    p;
  Option.value ~default:"?" !found

and uses_one dl p i =
  ignore dl;
  match Llvm.instr_opcode i with
  | Llvm.Opcode.Load -> true
  | Llvm.Opcode.Store -> not (Llvm.operand i 0 == p)
  | Llvm.Opcode.Call -> (not (keeps (callee i))) && not (Llvm.operand i (Llvm.num_operands i - 1) == p)
  | _ -> false

let next_instr i =
  match Llvm.instr_succ i with
  | Llvm.Before n -> n
  | Llvm.At_end _ -> Diagnostic.bug "held allocas: a call ends its block"

(* [a], of type [ty], given [slot] around each call [spills] names: the
   bytes the call may touch stored to the slot before the call and loaded
   back after it, and the call given the slot at the same offset. A list
   operation's first operand is a list's handle, and the call touches only
   that; any other call is taken to touch the whole value. Copying only the
   handle keeps the rest of the value what it was before the call, so that
   LLVM still knows a field the call cannot change, such as another list's
   block, as the same value across it. *)
let spill ctx ty a slot spills =
  let i8 = Llvm.i8_type ctx and i64 = Llvm.i64_type ctx in
  let at p offset b = if offset = 0L then p else Llvm.build_in_bounds_gep i8 p [| Llvm.const_of_int64 i64 offset true |] "" b in
  List.iter
    (function
      | Fine -> ()
      | Spill (c, k, offset) ->
          let b = Llvm.builder_before ctx c and after = Llvm.builder_before ctx (next_instr c) in
          let handle = k = 0 && match callee c with Some n -> starts "zane_list_" n | None -> false in
          let t, o = if handle then (List_handle.header ctx, offset) else (ty, 0L) in
          let into p = at p o b in
          let from = into a and dest = into slot in
          ignore (Llvm.build_store (Llvm.build_load t from "" b) dest b);
          ignore (Llvm.build_store (Llvm.build_load t dest "" after) from after);
          Llvm.set_operand c k (at slot offset b))
    (List.rev spills)

(* The held allocas of [fn], each kept, given its frame slot around the
   calls it reaches, or replaced by its frame slot. *)
let run ctx fn =
  if on && !order <> [] then begin
    let m = Llvm.global_parent fn in
    let dl = Llvm_target.DataLayout.of_string (Llvm.data_layout m) in
    List.iter
      (fun (a, h) ->
        let verdict = uses dl a 0L [] in
        if debug then
          Printf.eprintf "held %s: %s\n" (Llvm.value_name fn)
            (match verdict with
            | None -> "framed: " ^ why dl a
            | Some s -> Printf.sprintf "alloca, %d spills" (List.length s));
        match verdict with
        | None ->
            List.iter
              (fun store ->
                let load = Llvm.operand store 0 in
                Llvm.delete_instruction store;
                Llvm.delete_instruction load)
              h.fills;
            Llvm.replace_all_uses_with a h.slot;
            Llvm.delete_instruction a
        | Some spills -> spill ctx h.ty a h.slot spills)
      (List.rev !order)
  end;
  start ()
