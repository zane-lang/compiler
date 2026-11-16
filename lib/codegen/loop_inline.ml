(* A call made inside a loop to a small leaf function inlined at that
   call.

   LLVM's inliner costs a callee as it stands after its own optimization,
   with no notion of where it is called, so a helper a hot loop calls on
   every pass can stay a call: a maze carver's count of a cell's open
   neighbors is four checked index loads once its loop is unrolled, a cost
   of 480 against the threshold of 225, and stays a call in the carving
   loop (tests/perf `neighbors`). Raising the threshold for the whole
   program moves other programs both ways, by up to 20%.

   So, after LLVM's passes, a call is marked `alwaysinline` when it is in
   a cycle of its function's blocks and the callee is a leaf with no cycle
   of its own: a function of the program (not the runtime's or a foreign
   C function), whose calls are only to functions that do not return (the
   out-of-range stop) and LLVM's intrinsics, of at most [budget] instructions;
   then the inliner and a cleanup run again. A callee that keeps a loop is
   left: inlining SliceMap's byte compare `same` into its probe loop made
   Words 12% slower. *)

(* The most instructions a callee may have. *)
let budget = 128

let callee i =
  let c = Llvm.operand i (Llvm.num_operands i - 1) in
  match Llvm.classify_value c with Llvm.ValueKind.Function -> Some c | _ -> None

let is_call i =
  match Llvm.classify_value i with Llvm.ValueKind.Instruction Llvm.Opcode.Call -> true | _ -> false

let noreturn f =
  let kind = Llvm.enum_attr_kind "noreturn" in
  Array.exists
    (fun a -> match Llvm.repr_of_attr a with Llvm.AttrRepr.Enum (k, _) -> k = kind | _ -> false)
    (Llvm_extra.function_attrs f Llvm.AttrIndex.Function)

(* Blocks of [f] in a cycle: those in a strongly connected component of
   more than one block, or with an edge to themselves (Tarjan). *)
let cyclic f =
  let index = Hashtbl.create 64 and low = Hashtbl.create 64 and on_stack = Hashtbl.create 64 in
  let stack = ref [] and next = ref 0 and inside = Hashtbl.create 64 in
  let successors bb =
    match Llvm.block_terminator bb with
    | Some t -> List.init (Llvm.num_successors t) (Llvm.successor t)
    | None -> []
  in
  let rec visit v =
    Hashtbl.replace index v !next;
    Hashtbl.replace low v !next;
    incr next;
    stack := v :: !stack;
    Hashtbl.replace on_stack v ();
    List.iter
      (fun w ->
        if w == v then Hashtbl.replace inside v ();
        if not (Hashtbl.mem index w) then begin
          visit w;
          Hashtbl.replace low v (min (Hashtbl.find low v) (Hashtbl.find low w))
        end
        else if Hashtbl.mem on_stack w then Hashtbl.replace low v (min (Hashtbl.find low v) (Hashtbl.find index w)))
      (successors v);
    if Hashtbl.find low v = Hashtbl.find index v then begin
      let rec pop acc =
        match !stack with
        | w :: rest ->
            stack := rest;
            Hashtbl.remove on_stack w;
            if w == v then w :: acc else pop (w :: acc)
        | [] -> acc
      in
      let scc = pop [] in
      if List.length scc > 1 then List.iter (fun w -> Hashtbl.replace inside w ()) scc
    end
  in
  Llvm.iter_blocks (fun bb -> if not (Hashtbl.mem index bb) then visit bb) f;
  inside

(* A function the compiler made from the program. *)
let ours f =
  let n = Llvm.value_name f in
  let rec has i = i + 3 <= String.length n && (String.sub n i 3 = "%c$" || has (i + 1)) in
  String.contains n '$' && not (has 0)

(* A defined function's size, when it is a leaf of the program with no
   cycle of its own: every call it makes is to one of LLVM's intrinsics or
   to a function that does not return. *)
let leaf_size f =
  let counted acc i =
    if not (is_call i) then acc + 1
    else
      match callee i with
      | Some c when String.starts_with ~prefix:"llvm." (Llvm.value_name c) || noreturn c -> acc + 1
      | _ -> raise Exit
  in
  if Llvm.is_declaration f || (not (ours f)) || Hashtbl.length (cyclic f) > 0 then None
  else try Some (Llvm.fold_left_blocks (fun acc bb -> Llvm.fold_left_instrs counted acc bb) 0 f) with Exit -> None

let run m =
  let sizes = Hashtbl.create 64 in
  let size f =
    match Hashtbl.find_opt sizes f with
    | Some s -> s
    | None ->
        let s = leaf_size f in
        Hashtbl.replace sizes f s;
        s
  in
  let always = Llvm.create_enum_attr (Llvm.module_context m) "alwaysinline" 0L in
  (* A call [i] in [f] to a small leaf made always inlined. *)
  let mark f i =
    match if is_call i then callee i else None with
    | Some c when c != f -> (
        match size c with Some s when s <= budget -> Llvm.add_call_site_attr i always Llvm.AttrIndex.Function | _ -> ())
    | _ -> ()
  in
  Llvm.iter_functions
    (fun f ->
      if (not (Llvm.is_declaration f)) && ours f then
        let inside = cyclic f in
        Llvm.iter_blocks (fun bb -> if Hashtbl.mem inside bb then Llvm.iter_instrs (mark f) bb) f)
    m

let again =
  "always-inline,function(sroa,early-cse<memssa>,instcombine<no-verify-fixpoint>,simplifycfg,gvn,loop-mssa(licm<allowspeculation>),simplifycfg)"
