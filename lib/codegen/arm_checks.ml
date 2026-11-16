(* A check that both arms of a branch begin with, made once above the
   branch.

   A merge's `fromLeft Bool=if(a<=b) { work[k]=a; ... } :else() {
   work[k]=b; ... }` checks `k` against `work`'s count in each arm before
   its store. The two checks are the same, but each arm's stop sits between
   the branch and the arm's store, so LLVM cannot sink the two stores into
   one store of a select, and the merge's pick stays a branch that a random
   input mispredicts half the time, where with no check it is a `cmov`.

   A check is what [Merged_checks.check] finds: a conditional branch on an
   unsigned compare of an index against a bound, one of whose targets only
   stops the program out of range. Where a block ends in a conditional
   branch to two blocks that only it leads to, each of which does nothing
   but such a check of the same index against the same bound, both defined
   above the branch, the check goes above the branch, into a block of its
   own, and the arms' checks always pass. A failed check stops the program,
   so stopping before the branch rather than in an arm is the same to
   everything outside it: neither arm runs anything first. *)


(* Whether block [b] holds nothing but its terminator and the compare that
   terminator branches on. *)
let only_check b t c =
  let rec scan = function
    | Llvm.Before i when i == t -> true
    | Llvm.Before i when i == c -> scan (Llvm.instr_succ i)
    | Llvm.Before i when Llvm.instr_opcode i = Llvm.Opcode.Call -> (
        match Merged_checks.callee i with
        | Some n when Merged_checks.inert n -> scan (Llvm.instr_succ i)
        | _ -> false)
    | _ -> false
  in
  scan (Llvm.instr_begin b)

let func ctx f =
  let dom = lazy (Frame_shadow.dominators f) in
  let above v at =
    match Llvm.classify_value v with
    | Llvm.ValueKind.Instruction _ ->
        let vb = Llvm.instr_parent v and ab = Llvm.instr_parent at in
        if vb == ab then Frame_shadow.before v at else (Lazy.force dom) vb ab
    | _ -> true
  in
  let hoisted = ref 0 in
  let blocks = Llvm.fold_left_blocks (fun acc b -> b :: acc) [] f |> List.rev in
  List.iter
    (fun p ->
      match Llvm.block_terminator p with
      | Some t when Llvm.instr_opcode t = Llvm.Opcode.Br && Llvm.num_operands t = 3 && Merged_checks.check t = None -> (
          let a = Llvm.block_of_value (Llvm.operand t 2) and b = Llvm.block_of_value (Llvm.operand t 1) in
          let arm x =
            if x == p || not (Merged_checks.single_pred x) then None
            else
              match Llvm.block_terminator x with
              | Some tx -> (
                  match Merged_checks.check tx with
                  | Some (c, index, bound, _, passes_true) when only_check x tx c -> Some (tx, c, index, bound, passes_true)
                  | _ -> None)
              | None -> None
          in
          match (arm a, arm b) with
          | Some (ta, ca, ia, ba, pa), Some (tb, cb, ib, bb, pb)
            when a != b && ia == ib && ba == bb && above ia t && above ba t && Llvm.type_of ia == Llvm.type_of ba ->
              (* The stop of [a]'s check. *)
              let stop = Llvm.block_of_value (Llvm.operand ta (if pa then 1 else 2)) in
              let q = Llvm.insert_block ctx "arms" a in
              let cond = Llvm.operand t 0 in
              let into_q = Llvm.builder_at_end ctx q in
              ignore (Llvm.build_cond_br cond a b into_q);
              (* [a] and [b] hold no phi ([only_check]), so nothing names
                 [p] as where they were reached from. *)
              Llvm.delete_instruction t;
              let at_p = Llvm.builder_at_end ctx p in
              let ok = Llvm.build_icmp Llvm.Icmp.Ult ia ba "" at_p in
              ignore (Llvm.build_cond_br ok q stop at_p);
              let pass tx passes = Llvm.set_operand tx 0 (Llvm.const_int (Llvm.i1_type ctx) (if passes then 1 else 0)) in
              ignore (ca, cb);
              pass ta pa;
              pass tb pb;
              incr hoisted
          | _ -> ())
      | _ -> ())
    blocks

let run m =
    let ctx = Llvm.module_context m in
    Llvm.iter_functions (fun f -> if not (Llvm.is_declaration f) then func ctx f) m

let again =
  "function(instcombine<no-verify-fixpoint>,simplifycfg<sink-common-insts;speculate-blocks;hoist-common-insts>,instcombine<no-verify-fixpoint>,simplifycfg)"

(* The second half: in a diamond, a block branching to two arms that only
   it leads to and that both go on to one block, where each arm stores to
   the same address and does nothing after its store but arithmetic, the
   stores are moved to the ends of their arms. LLVM sinks the instructions
   two arms share only from their ends up, and an arm's other work (a
   different counter stepped) below its store stops it before it reaches
   the stores; at the ends, it sinks them into one store of a phi, and the
   arms left with only arithmetic become selects. *)

let pure i =
  match Llvm.instr_opcode i with
  | Llvm.Opcode.Add | Llvm.Opcode.Sub | Llvm.Opcode.Mul | Llvm.Opcode.And | Llvm.Opcode.Or | Llvm.Opcode.Xor
  | Llvm.Opcode.Shl | Llvm.Opcode.LShr | Llvm.Opcode.AShr | Llvm.Opcode.ICmp | Llvm.Opcode.Select
  | Llvm.Opcode.GetElementPtr | Llvm.Opcode.SExt | Llvm.Opcode.ZExt | Llvm.Opcode.Trunc ->
      true
  | _ -> false

(* The last store of block [x], if nothing after it but pure instructions
   and an unconditional branch. A volatile or atomic store is never moved:
   the plain store that replaces it would lose its ordering. *)
let last_store x =
  let rec scan acc = function
    | Llvm.Before i when Llvm.instr_opcode i = Llvm.Opcode.Store ->
        let plain = not (Llvm.is_volatile i || Llvm_extra.is_atomic i) in
        scan (if plain then Some i else None) (Llvm.instr_succ i)
    | Llvm.Before i when Llvm.instr_opcode i = Llvm.Opcode.Br && Llvm.num_operands i = 1 -> acc
    | Llvm.Before i when pure i -> scan acc (Llvm.instr_succ i)
    | Llvm.Before i -> scan None (Llvm.instr_succ i)
    | Llvm.At_end _ -> None
  in
  scan None (Llvm.instr_begin x)

let stores_func ctx f =
  let moved = ref 0 in
  let move s =
    let x = Llvm.instr_parent s in
    let t = Option.get (Llvm.block_terminator x) in
    let b = Llvm.builder_before ctx t in
    let n = Llvm.build_store (Llvm.operand s 0) (Llvm.operand s 1) b in
    Llvm.set_alignment (Llvm.alignment s) n;
    List.iter
      (fun k -> match Llvm.metadata s k with Some md -> Llvm.set_metadata n k md | None -> ())
      [ Llvm.mdkind_id ctx "tbaa"; Llvm.mdkind_id ctx "alias.scope"; Llvm.mdkind_id ctx "noalias" ];
    Llvm.delete_instruction s
  in
  Llvm.iter_blocks
    (fun p ->
      match Llvm.block_terminator p with
      | Some t when Llvm.instr_opcode t = Llvm.Opcode.Br && Llvm.num_operands t = 3 -> (
          let a = Llvm.block_of_value (Llvm.operand t 2) and b = Llvm.block_of_value (Llvm.operand t 1) in
          let goes x =
            match Llvm.block_terminator x with
            | Some tx when Llvm.instr_opcode tx = Llvm.Opcode.Br && Llvm.num_operands tx = 1 ->
                Some (Llvm.block_of_value (Llvm.operand tx 0))
            | _ -> None
          in
          if a != b && Merged_checks.single_pred a && Merged_checks.single_pred b then
            match (goes a, goes b, last_store a, last_store b) with
            | Some ja, Some jb, Some sa, Some sb
              when ja == jb && Llvm.operand sa 1 == Llvm.operand sb 1
                   && Llvm.type_of (Llvm.operand sa 0) == Llvm.type_of (Llvm.operand sb 0) ->
                move sa;
                move sb;
                incr moved
            | _ -> ())
      | _ -> ())
    f

let stores_run m =
    let ctx = Llvm.module_context m in
    Llvm.iter_functions (fun f -> if not (Llvm.is_declaration f) then stores_func ctx f) m

let stores_again =
  "function(simplifycfg<sink-common-insts;speculate-blocks>,instcombine<no-verify-fixpoint>,simplifycfg)"
