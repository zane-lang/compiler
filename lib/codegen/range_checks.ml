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
   between the lowest and the highest pass when both do: they are within an
   unsigned range below a bound that is a count, so below 2^63, and adding
   a constant within it does not wrap. *)


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

let func ctx f =
  let dom = lazy (Frame_shadow.dominators f) in
  let above v at =
    match Llvm.classify_value v with
    | Llvm.ValueKind.Instruction _ ->
        let vb = Llvm.instr_parent v and ab = Llvm.instr_parent at in
        if vb == ab then Frame_shadow.before v at else (Lazy.force dom) vb ab
    | _ -> true
  in
  let folded = ref 0 in
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
              let calm =
                let rec scan = function
                  | Llvm.Before i when i == t -> true
                  | Llvm.Before i when Llvm.instr_opcode i = Llvm.Opcode.Call -> (
                      match Merged_checks.callee i with
                      | Some n when Merged_checks.inert n -> scan (Llvm.instr_succ i)
                      | _ -> false)
                  | Llvm.Before i -> (
                      match Llvm.instr_opcode i with
                      | Llvm.Opcode.Invoke | Llvm.Opcode.Fence | Llvm.Opcode.AtomicCmpXchg | Llvm.Opcode.AtomicRMW -> false
                      | _ -> scan (Llvm.instr_succ i))
                  | Llvm.At_end _ -> false
                in
                scan (Llvm.instr_begin b)
              in
              if calm then
                match Merged_checks.check t with
                | Some (c, i, bound, cont, passes) ->
                    let bi, k = split i in
                    if bi == base && bound == bound0 && c != c0 then begin
                      if k < !lo then lo := k;
                      if k > !hi then hi := k;
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
          if !later <> [] && above base t0 && above bound0 c0 && only_branch && Llvm.type_of base == Llvm.type_of bound0 then begin
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
            incr folded
          end)
      | _ -> ())
    blocks

(* The second form, as LLVM leaves a strip-mined loop's checks: a check
   made an exit test `icmp eq b, (n + k) >> s` by the loop passes, where
   the loop's counter `b` starts at 0, steps by one and leaves the loop
   when `b + 1 == n >> s` (or `(n + j) >> s`, j <= k). Inside the loop `b`
   is below the loop's end, which is no more than the tested value, so the
   test never holds and the stop is never reached. *)
let shifted v =
  (* [v] as (n, k, s) for `lshr (add nuw n, k), s` or `lshr n, s`. *)
  match Llvm.classify_value v with
  | Llvm.ValueKind.Instruction Llvm.Opcode.LShr -> (
      match Llvm.int64_of_const (Llvm.operand v 1) with
      | Some sh ->
          let x = Llvm.operand v 0 in
          let n, k =
            match Llvm.classify_value x with
            | Llvm.ValueKind.Instruction Llvm.Opcode.Add -> (
                match Llvm.int64_of_const (Llvm.operand x 1) with Some k when k >= 0L -> (Llvm.operand x 0, k) | _ -> (x, 0L))
            | _ -> (x, 0L)
          in
          Some (n, k, sh)
      | None -> None)
  | _ -> None

let exits ctx f =
  let folded = ref 0 in
  (* Each counter: a phi of 0 and its own plus one, and the end its latch
     leaves at. *)
  let ends = Hashtbl.create 8 in
  Llvm.iter_blocks
    (fun b ->
      Llvm.iter_instrs
        (fun i ->
          if Llvm.instr_opcode i = Llvm.Opcode.ICmp && Llvm.icmp_predicate i = Some Llvm.Icmp.Eq then
            let x = Llvm.operand i 0 and e = Llvm.operand i 1 in
            match Llvm.classify_value x with
            | Llvm.ValueKind.Instruction Llvm.Opcode.Add when Llvm.int64_of_const (Llvm.operand x 1) = Some 1L -> (
                let phi = Llvm.operand x 0 in
                match Llvm.classify_value phi with
                | Llvm.ValueKind.Instruction Llvm.Opcode.PHI ->
                    let inc = Llvm.incoming phi in
                    let from_zero = List.exists (fun (v, _) -> Llvm.int64_of_const v = Some 0L) inc in
                    let steps = List.for_all (fun (v, _) -> Llvm.int64_of_const v = Some 0L || v == x) inc in
                    if from_zero && steps && List.length inc = 2 then
                      Option.iter (fun sh -> Hashtbl.replace ends phi sh) (shifted e)
                | _ -> ())
            | _ -> ())
        b)
    f;
  Llvm.iter_blocks
    (fun b ->
      match Llvm.block_terminator b with
      | Some t when Llvm.instr_opcode t = Llvm.Opcode.Br && Llvm.num_operands t = 3 -> (
          let c = Llvm.operand t 0 in
          match Llvm.classify_value c with
          | Llvm.ValueKind.Instruction Llvm.Opcode.ICmp when Llvm.icmp_predicate c = Some Llvm.Icmp.Eq -> (
              let x = Llvm.operand c 0 and a = Llvm.operand c 1 in
              (* The stop is where the test holding leads. *)
              let if_true = Llvm.block_of_value (Llvm.operand t 2) in
              match (Hashtbl.find_opt ends x, shifted a) with
              | Some (n, j, s), Some (n', k, s') when n == n' && s = s' && j <= k && Merged_checks.stops if_true ->
                  Llvm.set_operand t 0 (Llvm.const_int (Llvm.i1_type ctx) 0);
                  incr folded
              | _ -> ())
          | _ -> ())
      | _ -> ())
    f

let run m =
    let ctx = Llvm.module_context m in
    Llvm.iter_functions (fun f -> if not (Llvm.is_declaration f) then (func ctx f; exits ctx f)) m

let again =
  "function(instcombine<no-verify-fixpoint>,simplifycfg,slp-vectorizer,vector-combine,instcombine<no-verify-fixpoint>,simplifycfg)"
