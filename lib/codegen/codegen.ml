(* Codegen's entry module (docs/design/lowering.md §1). *)

type tier = Tiers.tier = Plain | Tier0 | Tier1

(* Lowering refuses each type that reaches the size limit (Cgt.Nodes.Ty.limit)
   where it is named. A frame is laid out here, from slots each below it, and
   one whose slots together reach it is refused as the build's error. *)

(* How many contexts [with_program] has made and not yet disposed, which
   the unit tests read. *)
let live = Atomic.make 0
let live_contexts () = Atomic.get live

(* The program's module lives only while [f] runs: its context and the
   module are disposed however [f] or the emit ends, since LLVM's bindings
   free neither on their own. *)
let with_module ?target ?pack ?memos ?fixed_region ?spawned_fixed_region p f =
  Result.bind (Build.target_machine ?target ~optimize:false ()) (fun (triple, tm) ->
      let data_layout = Llvm_target.DataLayout.as_string (Llvm_target.TargetMachine.data_layout tm) in
      let ctx = Llvm.create_context () in
      Atomic.incr live;
      Fun.protect
        ~finally:(fun () ->
          Llvm.dispose_context ctx;
          Atomic.decr live)
        (fun () ->
          let m = Llvm.create_module ctx "zane" in
          Fun.protect
            ~finally:(fun () -> Llvm.dispose_module m)
            (fun () ->
              match Emit.program ?fixed_region ?spawned_fixed_region ?pack ?memos ~triple ~data_layout m p with
              | () -> f m
              | exception Cgt.Nodes.Ty.Too_large ->
                  Error "a scope's frame takes 2^48 bytes or more, past the limit on any value's size")))

(* What LLVM's `-O2` makes of the program as it is, for [Cgt.Memo.plan].
   First, whether it still calls [s] back from its own cycle at least
   twice, a call inside a loop counting twice: [same] names the functions
   of [s]'s cycle. A function whose every call LLVM inlined and folded has
   nothing left for a table to save, nor does one whose repeated calls LLVM
   merged or deleted; a dispatcher would only stop LLVM doing so. Nor does
   one LLVM has found some of whose parameters never matter, and dropped:
   a table would key on them, and keep alive the work that makes them. Second,
   the fewest instructions a call to [s] runs on its way to a return, a
   call it makes counting one, which may be fewer than its body's nodes
   once LLVM has dropped what nothing reads. *)
let still_called ?target ?pack ?fixed_region ?spawned_fixed_region p =
  let names = Hashtbl.create 64 in
  List.iter
    (fun (f : Cgt.Nodes.Func.t) ->
      let s = f.Cgt.Nodes.Func.symbol in
      Hashtbl.replace names (if pack = Some true then s ^ Emit.packed else s) s)
    p.Cgt.Nodes.Program.funcs;
  (* Each function's calls by symbol, with whether the call is in a loop,
     and its cheapest path in instructions. *)
  let sites = Hashtbl.create 64 and cheapest = Hashtbl.create 64 in
  (* The functions LLVM gave fewer parameters than codegen did. *)
  let dropped = Hashtbl.create 8 in
  let found =
    with_module ?target ?pack ?fixed_region ?spawned_fixed_region p (fun m ->
        Result.map
          (fun _ ->
            Llvm.iter_functions
              (fun fn ->
                match Hashtbl.find_opt names (Llvm.value_name fn) with
                | None -> ()
                | Some s ->
                    (* Whether [b] can reach itself again. *)
                    let looping b =
                      let seen = Hashtbl.create 16 in
                      let rec from b' =
                        Array.exists
                          (fun n ->
                            n == b
                            ||
                            let v = Llvm.value_of_block n in
                            (not (Hashtbl.mem seen v))
                            && (Hashtbl.replace seen v ();
                                from n))
                          (match Llvm.block_terminator b' with Some t -> Llvm.successors t | None -> [||])
                      in
                      from b
                    in
                    Llvm.iter_blocks
                      (fun b ->
                        let inside = lazy (looping b) in
                        Llvm.iter_instrs
                          (fun i ->
                            match Llvm.instr_opcode i with
                            | Llvm.Opcode.Call -> (
                                let callee = Llvm.operand i (Llvm.num_operands i - 1) in
                                match Hashtbl.find_opt names (Llvm.value_name callee) with
                                | Some c -> Hashtbl.add sites s (c, if Lazy.force inside then 2 else 1)
                                | None -> ())
                            | _ -> ())
                          b)
                      fn;
                    (* Each block's fewest instructions from the entry, through
                       itself, until no block's count falls. *)
                    let size b = Llvm.fold_left_instrs (fun n _ -> n + 1) 0 b in
                    let dist = Hashtbl.create 16 in
                    let entry = Llvm.entry_block fn in
                    Hashtbl.replace dist (Llvm.value_of_block entry) (size entry);
                    let changed = ref true in
                    while !changed do
                      changed := false;
                      Llvm.iter_blocks
                        (fun b ->
                          match Hashtbl.find_opt dist (Llvm.value_of_block b) with
                          | None -> ()
                          | Some d ->
                              Array.iter
                                (fun n ->
                                  let v = Llvm.value_of_block n and d' = d + size n in
                                  match Hashtbl.find_opt dist v with
                                  | Some old when old <= d' -> ()
                                  | _ ->
                                      Hashtbl.replace dist v d';
                                      changed := true)
                                (match Llvm.block_terminator b with Some t -> Llvm.successors t | None -> [||]))
                        fn
                    done;
                    Llvm.iter_blocks
                      (fun b ->
                        match (Llvm.block_terminator b, Hashtbl.find_opt dist (Llvm.value_of_block b)) with
                        | Some t, Some d when Llvm.instr_opcode t = Llvm.Opcode.Ret ->
                            let least = match Hashtbl.find_opt cheapest s with Some l -> min l d | None -> d in
                            Hashtbl.replace cheapest s least
                        | _ -> ())
                      fn)
              m)
          (let before = Hashtbl.create 64 in
           Llvm.iter_functions (fun fn -> Hashtbl.replace before (Llvm.value_name fn) (Array.length (Llvm.params fn))) m;
           let prepared = Build.prepare ?target ~optimize:true m in
           Llvm.iter_functions
             (fun fn ->
               match (Hashtbl.find_opt names (Llvm.value_name fn), Hashtbl.find_opt before (Llvm.value_name fn)) with
               | Some s, Some n when Array.length (Llvm.params fn) < n -> Hashtbl.replace dropped s ()
               | _ -> ())
             m;
           prepared))
  in
  match found with
  | Ok () ->
      ( (fun s same ->
          (not (Hashtbl.mem dropped s))
          && List.fold_left (fun n (c, w) -> if same c then n + w else n) 0 (Hashtbl.find_all sites s) >= 2),
        Hashtbl.find_opt cheapest )
  | Error _ -> ((fun _ _ -> false), fun _ -> None)

(* The program's module lives only while [f] runs: its context and the
   module are disposed however [f] or the emit ends, since LLVM's bindings
   free neither on their own. With [memoize], the functions [Cgt.Memo]
   picks are remembered; in an [optimize]d build, only those
   [still_called] leaves, and each one's cheapest call is the fewer of its
   nodes and of its instructions there. That is worked out only once a
   function passes every other test, so a program with none is compiled
   once. *)
let with_program ?target ?pack ?(memoize = false) ?(optimize = false) ?fixed_region ?spawned_fixed_region p f =
  let p, memos =
    if not memoize then (p, [])
    else if optimize then
      let view = lazy (still_called ?target ?pack ?fixed_region ?spawned_fixed_region p) in
      Cgt.Memo.plan
        ~keep:(fun s same -> fst (Lazy.force view) s same)
        ~measured:(fun s -> if Lazy.is_val view then snd (Lazy.force view) s else None)
        p
    else Cgt.Memo.plan p
  in
  with_module ?target ?pack ~memos ?fixed_region ?spawned_fixed_region p f

let ir m = Llvm.string_of_llmodule m

let target_cpu ?target () =
  Result.map
    (fun (_, tm) -> Llvm_target.TargetMachine.cpu tm)
    (Build.target_machine ?target ~optimize:true ())

let executable ?target ?optimize ?tier ?link m output =
  Build.executable ?target ?optimize ?tier ?link m output
let shared_library ?target m output = Build.shared_library ?target m output
let object_file ?target ?optimize ?tier m output = Build.object_file ?target ?optimize ?tier m output
let prepare ?target ?optimize ?tier m = Result.map ignore (Build.prepare ?target ?optimize ?tier m)
let bundle_runtime ~target ~optimize dir = Build.bundle_runtime ~target ~optimize dir
