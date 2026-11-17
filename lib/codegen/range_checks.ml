(* The
   checks of `x + 0`, `x + 1`, ... `x + k` against one bound, made on one
   straight path, made as one check of the lowest and one of the highest
   at the first of them.

   A strip-mined loop ([Optimize.Strip]) reads `data[x]`, `data[x+1]`, ...
   in its copies of the body, each checked on its own, so the block of
   copies is cut into as many blocks as checks and the SLP vectorizer,
   which works within a block, cannot make the copies' independent
   arithmetic one vector operation.

   As [Merged_checks] argues, a failed check stops the program, so where a
   later check on the path would fail, stopping at the first is the same to
   everything outside it (no call between them writes output). The indices
   between the lowest and the highest pass when both do: the lowest is
   below a bound that is a count, so below 2^63, and every offset is
   within [near] of 0, so going from the lowest up to any other index adds
   less than 2^63 and does not wrap. *)

(* The largest offset, either way, of a check a run takes in. *)
let near = Int64.shift_left 1L 31

let small k = Int64.compare (Int64.abs k) near <= 0 && k <> Int64.min_int


(* [v] as a base and a constant offset: `add base, c` or `base`. *)
let split v =
  match Llvm.classify_value v with
  | Llvm.ValueKind.Instruction Llvm.Opcode.Add -> (
      let a = Llvm.operand v 0 and b = Llvm.operand v 1 in
      match (Llvm.int64_of_const b, Llvm.int64_of_const a) with
      | Some c, _ -> (a, c)
      | None, Some c -> (b, c)
      | None, None -> (v, 0L))
  | _ -> (v, 0L)

(* Whether block [b], ending in [t], runs nothing but inert calls, pure
   arithmetic, and loads and stores that are neither volatile nor atomic
   ([Merged_checks.ordered]), so a check after it may be made before it. *)
let calm b t =
  let rec scan = function
    | Llvm.Before i when i == t -> true
    | Llvm.Before i when Llvm.instr_opcode i = Llvm.Opcode.Call -> (
        match Merged_checks.callee i with Some n when Merged_checks.inert n -> scan (Llvm.instr_succ i) | _ -> false)
    | Llvm.Before i when Merged_checks.ordered i || Llvm.instr_opcode i = Llvm.Opcode.Invoke -> false
    | Llvm.Before i -> scan (Llvm.instr_succ i)
    | Llvm.At_end _ -> false
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
  let done_ = Hashtbl.create 16 in
  let blocks = Llvm.fold_left_blocks (fun acc b -> b :: acc) [] f |> List.rev in
  List.iter
    (fun b0 ->
      match Option.bind (Llvm.block_terminator b0) Merged_checks.check with
      | Some (c0, index0, bound0, next, passes0) when not (Hashtbl.mem done_ c0) -> (
          let t0 = Option.get (Llvm.block_terminator b0) in
          let base, k0 = split index0 in
          let lo = ref k0 and hi = ref k0 and later = ref [] in
          (* The path from the first check, through blocks only it leads to
             that run nothing but inert calls, pure arithmetic, loads and
             stores, to checks of base + k against the same bound. *)
          let rec follow b steps =
            if steps > 0 && Merged_checks.single_pred b then
              let t = Option.get (Llvm.block_terminator b) in
              let calm = calm b t in
              if calm then
                match Merged_checks.check t with
                | Some (c, i, bound, cont, passes) ->
                    let bi, k = split i in
                    if bi == base && bound == bound0 && c != c0 && small k then begin
                      lo := min !lo k;
                      hi := max !hi k;
                      later := (t, passes) :: !later
                    end;
                    follow cont (steps - 1)
                | None -> (
                    match Llvm.instr_opcode t with
                    | Llvm.Opcode.Br when Llvm.num_operands t = 1 ->
                        follow (Llvm.block_of_value (Llvm.operand t 0)) (steps - 1)
                    | _ -> ())
          in
          follow next 64;
          let only_branch = match Llvm.use_begin c0 with Some u -> Llvm.use_succ u = None | None -> false in
          if !later <> [] && small k0 && above base t0 && above bound0 c0 && only_branch && Llvm.type_of base == Llvm.type_of bound0 then begin
            Hashtbl.replace done_ c0 ();
            let ty = Llvm.type_of base in
            let at = Llvm.builder_before ctx t0 in
            let offset k = if k = 0L then base else Llvm.build_add base (Llvm.const_of_int64 ty k true) "" at in
            let lo_ok = Llvm.build_icmp Llvm.Icmp.Ult (offset !lo) bound0 "" at in
            let hi_ok = Llvm.build_icmp Llvm.Icmp.Ult (offset !hi) bound0 "" at in
            let both = Llvm.build_and lo_ok hi_ok "" at in
            Llvm.set_operand t0 0 (if passes0 then both else Llvm.build_not both "" at);
            List.iter
              (fun (t, passes) -> Llvm.set_operand t 0 (Llvm.const_int (Llvm.i1_type ctx) (if passes then 1 else 0)))
              !later;
          end)
      | _ -> ())
    blocks

(* The second form, as LLVM leaves a strip-mined loop's checks: a check
   made an exit test `icmp eq b, (n + k) >> s` by the loop passes, where
   the loop's counter `b` starts at 0, steps by one and leaves the loop
   when `b + 1 == (n + j) >> s`, j <= k (the lowest such end, where it
   has more than one), and is entered only when `n >= 2^s`, so that end
   is at least one. Every use of `b` is in the loop or after it, where `b`
   is below that end, which is no more than the tested value since neither
   sum wraps (`nuw`); so the test never holds, and is made false wherever
   its holding would lead. *)
let shifted v =
  (* [v] as (n, k, s) for `lshr (add nuw n, k), s` or `lshr n, s`. *)
  match Llvm.classify_value v with
  | Llvm.ValueKind.Instruction Llvm.Opcode.LShr -> (
      match Llvm.int64_of_const (Llvm.operand v 1) with
      | Some sh when sh >= 0L && sh < 63L ->
          let x = Llvm.operand v 0 in
          let n, k =
            match Llvm.classify_value x with
            | Llvm.ValueKind.Instruction Llvm.Opcode.Add when Llvm_extra.has_nuw x -> (
                match Llvm.int64_of_const (Llvm.operand x 1) with Some k when k >= 0L -> (Llvm.operand x 0, k) | _ -> (x, 0L))
            | _ -> (x, 0L)
          in
          Some (n, k, sh)
      | _ -> None)
  | _ -> None

(* Whether the branch [t] leads to [into] only when [n] is at least [low]:
   it tests [n], or a value [n] widens with `zext`, against a constant, on
   the edge to [into]. *)
let at_least t into n low =
  Llvm.num_operands t = 3
  &&
  let c = Llvm.operand t 0 in
  let taken = Llvm.block_of_value (Llvm.operand t 2) == into in
  let not_taken = Llvm.block_of_value (Llvm.operand t 1) == into in
  match (Llvm.classify_value c, Llvm.icmp_predicate c) with
  | Llvm.ValueKind.Instruction Llvm.Opcode.ICmp, Some p when taken <> not_taken -> (
      let a = Llvm.operand c 0 in
      let names_n =
        a == n
        || (Llvm.classify_value n = Llvm.ValueKind.Instruction Llvm.Opcode.ZExt && Llvm.operand n 0 == a)
      in
      match Llvm.int64_of_const (Llvm.operand c 1) with
      | Some k when names_n && k >= 0L -> (
          (* The smallest [a] the edge allows. *)
          let least =
            match (p, taken) with
            | Llvm.Icmp.Uge, true | Llvm.Icmp.Ult, false -> Some k
            | Llvm.Icmp.Ugt, true | Llvm.Icmp.Ule, false -> Some (Int64.add k 1L)
            | Llvm.Icmp.Ne, true | Llvm.Icmp.Eq, false when k = 0L -> Some 1L
            | _ -> None
          in
          match least with Some l -> Int64.compare l low >= 0 | None -> false)
      | _ -> false)
  | _ -> false

(* Whether block [b] leads to [into] only when [n] is at least [low]: its
   branch tests that on the edge, or it ends in a plain `br` and is reached
   from one branch alone, of a block that does, within [steps] such blocks
   (a preheader LLVM put between the guard and the loop, as when the loop
   was inlined). *)
let rec guarded b into n low steps =
  match Llvm.block_terminator b with
  | Some g when at_least g into n low -> true
  | Some g when steps > 0 && Llvm.instr_opcode g = Llvm.Opcode.Br && Llvm.num_operands g = 1 && Merged_checks.single_pred b -> (
      match Llvm.use_begin (Llvm.value_of_block b) with
      | Some u -> (
          let t = Llvm.user u in
          match Llvm.classify_value t with
          | Llvm.ValueKind.Instruction Llvm.Opcode.Br -> guarded (Llvm.instr_parent t) b n low (steps - 1)
          | _ -> false)
      | None -> false)
  | _ -> false

(* Whether the branch [t] on a stop test leaves the loop whose header is
   [h] and whose latch is [back]: it ends the latch and its false edge
   goes back to [h], or it ends the one block leading to the latch, its
   false edge to the latch, which then goes back to [h]. *)
let leaves t h back =
  let if_false = Llvm.block_of_value (Llvm.operand t 1)
  and if_true = Llvm.block_of_value (Llvm.operand t 2) in
  let goes_back b =
    match Llvm.block_terminator b with
    | Some g -> Array.exists (fun s -> s == h) (Llvm.successors g)
    | None -> false
  in
  if back == Llvm.instr_parent t then if_false == h && if_true != h
  else if_false == back && if_true != back && if_true != h && Merged_checks.single_pred back && goes_back back

(* For the exit test `icmp eq (add phi, 1), e` of a loop: the test's only
   use is the branch ending the latch, whose other edge goes back to the
   phi's block, or the branch ending the one block that leads to the
   latch (where LLVM leaves a range check last in the latch, after the
   stop); the phi starts at 0 from a block that enters the loop only when
   [e]'s `n` is at least 2^s ([guarded]), and steps by one from the latch.
   The phi and [e] as [shifted] reads it. *)
let counter_end i =
  if Llvm.instr_opcode i <> Llvm.Opcode.ICmp || Llvm.icmp_predicate i <> Some Llvm.Icmp.Eq then None
  else
    let x = Llvm.operand i 0 and e = Llvm.operand i 1 in
    let latch_branch =
      match Llvm.use_begin i with
      | Some u when Llvm.use_succ u = None ->
          let t = Llvm.user u in
          if Llvm.instr_opcode t = Llvm.Opcode.Br && Llvm.num_operands t = 3 && Llvm.operand t 0 == i then Some t else None
      | _ -> None
    in
    match (Llvm.classify_value x, latch_branch, shifted e) with
    | Llvm.ValueKind.Instruction Llvm.Opcode.Add, Some t, Some ((n, _, sh) as ends)
      when Llvm.int64_of_const (Llvm.operand x 1) = Some 1L ->
        let phi = Llvm.operand x 0 in
        let is_phi = Llvm.classify_value phi = Llvm.ValueKind.Instruction Llvm.Opcode.PHI in
        (* Only a phi has incoming values to read. *)
        let incoming = if is_phi then Some (Llvm.instr_parent phi, Llvm.incoming phi) else None in
        let entered =
          match incoming with
          | Some (h, [ (v0, p0); (v1, p1) ]) ->
              let from_entry, from_latch =
                if Llvm.int64_of_const v0 = Some 0L then ((v0, p0), (v1, p1)) else ((v1, p1), (v0, p0))
              in
              let (start, entry), (step, back) = (from_entry, from_latch) in
              Llvm.int64_of_const start = Some 0L
              && step == x && entry != back && leaves t h back
              && guarded entry h n (Int64.shift_left 1L (Int64.to_int sh)) 4
          | _ -> false
        in
        if entered then Some (phi, ends) else None
    | _ -> None

let exits ctx f =
  (* Each counter with the end it leaves at. Every exit test bounds it, so
     of two over the same `n` and shift the lower holds; of two over
     different ones, the first is kept. *)
  let ends = Hashtbl.create 8 in
  let record (phi, ((n, j, s) as e)) =
    match Hashtbl.find_opt ends phi with
    | Some (n', j', s') when n == n' && s = s' && j < j' -> Hashtbl.replace ends phi e
    | Some _ -> ()
    | None -> Hashtbl.replace ends phi e
  in
  Llvm.iter_blocks (fun b -> Llvm.iter_instrs (fun i -> Option.iter record (counter_end i)) b) f;
  Llvm.iter_blocks
    (fun b ->
      match Llvm.block_terminator b with
      | Some t when Llvm.instr_opcode t = Llvm.Opcode.Br && Llvm.num_operands t = 3 -> (
          let c = Llvm.operand t 0 in
          match Llvm.classify_value c with
          | Llvm.ValueKind.Instruction Llvm.Opcode.ICmp when Llvm.icmp_predicate c = Some Llvm.Icmp.Eq -> (
              let x = Llvm.operand c 0 and a = Llvm.operand c 1 in
              (* The test never holds, wherever its holding would lead: a
                 stop, or a block that first writes back what the loop
                 kept in registers. *)
              match (Hashtbl.find_opt ends x, shifted a) with
              | Some (n, j, s), Some (n', k, s') when n == n' && s = s' && j <= k ->
                  Llvm.set_operand t 0 (Llvm.const_int (Llvm.i1_type ctx) 0)
              | _ -> ())
          | _ -> ())
      | _ -> ())
    f

let run m =
  let ctx = Llvm.module_context m in
  Llvm.iter_functions (fun f -> if not (Llvm.is_declaration f) then (func ctx f; exits ctx f)) m

let again =
  "function(instcombine<no-verify-fixpoint>,simplifycfg,slp-vectorizer,vector-combine,instcombine<no-verify-fixpoint>,simplifycfg)"
