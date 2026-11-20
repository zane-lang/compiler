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
     the local is held. *)
  slot : Llvm.llvalue;
  (* The local's LLVM type, which a store or a load of it whole takes. *)
  ty : Llvm.lltype;
  (* The record of the local's scope, the frame's start. *)
  arena : Llvm.llvalue;
}

(* Every held alloca of the function being emitted. *)
let table : (Llvm.llvalue, held) Hashtbl.t = Hashtbl.create 16

let record alloca h = Hashtbl.replace table alloca h
let find p = Hashtbl.find_opt table p

let callee i =
  let f = Llvm.operand i (Llvm.num_operands i - 1) in
  if Llvm.classify_value f = Llvm.ValueKind.Function then Some (Llvm.value_name f) else None

let starts p s = String.length s >= String.length p && String.sub s 0 (String.length p) = p

(* Calls that may keep the address past their return: the runtime lists a
   held slot for its drain. *)
let keeps = function Some "zane_hold" -> true | _ -> false

(* Intrinsics SROA reads an alloca through. *)
let through = function
  | Some n ->
      starts "llvm.lifetime" n || starts "llvm.memcpy" n || starts "llvm.memmove" n || starts "llvm.memset" n
  | None -> false

type use = Spill of Llvm.llvalue * int * int64 (* a call, its operand, the offset *) | Fine

(* The uses of [p], an address [offset] bytes into the alloca, or [None]
   when one of them gives up on it. *)
let rec uses dl p offset acc =
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
              if through name then ()
              else if keeps name || Llvm.operand i (Llvm.num_operands i - 1) == p then result := None
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

let next_instr i =
  match Llvm.instr_succ i with
  | Llvm.Before n -> n
  | Llvm.At_end _ -> Diagnostic.bug "held allocas: a call ends its block"

(* The held allocas of [fn], each kept, given its frame slot around the
   calls it reaches, or replaced by its frame slot. *)
let run ctx fn =
  if on && Hashtbl.length table > 0 then begin
    let m = Llvm.global_parent fn in
    let dl = Llvm_target.DataLayout.of_string (Llvm.data_layout m) in
    let i8 = Llvm.i8_type ctx and i64 = Llvm.i64_type ctx in
    Hashtbl.iter
      (fun a h ->
        match uses dl a 0L [] with
        | None ->
            Llvm.replace_all_uses_with a h.slot;
            Llvm.delete_instruction a
        | Some spills ->
            let seen = Hashtbl.create 4 in
            List.iter
              (function
                | Fine -> ()
                | Spill (c, k, offset) ->
                    let b = Llvm.builder_before ctx c in
                    if not (Hashtbl.mem seen c) then begin
                      Hashtbl.replace seen c ();
                      ignore (Llvm.build_store (Llvm.build_load h.ty a "" b) h.slot b);
                      let after = Llvm.builder_before ctx (next_instr c) in
                      ignore (Llvm.build_store (Llvm.build_load h.ty h.slot "" after) a after)
                    end;
                    let at =
                      if offset = 0L then h.slot
                      else Llvm.build_in_bounds_gep i8 h.slot [| Llvm.const_of_int64 i64 offset true |] "" b
                    in
                    Llvm.set_operand c k at)
              spills)
      table;
    Hashtbl.reset table
  end
