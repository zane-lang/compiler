(* EXPERIMENT (LangArena zane-vs-goose; on with ZANE_LOOP_INLINE=N): a
   call made inside a loop to a small leaf function inlined at that call.

   LLVM's inliner costs a callee as it stands after its own optimization,
   with no notion of where it is called, so a helper a hot loop calls on
   every pass can stay a call: Maze::Generator's `adjacentOpen`, the count
   of a cell's open neighbors, is four checked index loads once its loop
   is unrolled, a cost of 480 against the threshold of 225, and stays a
   call in `dig`'s loop, where Goose's `count(...) { ... }` is inline by
   construction. Raising the threshold for the whole program moves other
   tests both ways (Graph::BFS +15%, GameOfLife +20%).

   So, after LLVM's passes, a call is marked `alwaysinline` when it is in
   a cycle of its function's blocks and the callee is a leaf with no cycle
   of its own: a function of the program (not the runtime's or a foreign
   C function), whose calls are only to functions that do not return (the
   out-of-range stop) and LLVM's intrinsics, of at most N instructions;
   then the inliner and a cleanup run again. A callee that keeps a loop is
   left: inlining SliceMap's byte compare `same` into its probe loop made
   Words 12% slower. *)

let limit () =
  match Sys.getenv_opt "ZANE_LOOP_INLINE" with Some n -> int_of_string_opt n | None -> None

let on () = limit () <> None

(* ZANE_LOOP_INLINE_LOOPS=M: a callee with a cycle of its own is taken too
   when it has at most M instructions. *)
(* With it, a callee may also call the runtime's push, the growth of a
   full list, which is the cold side of a push. *)
let pushes = [ "zane_list_push"; "zane_list_reserve" ]

let loops () =
  match Sys.getenv_opt "ZANE_LOOP_INLINE_LOOPS" with Some n -> int_of_string_opt n | None -> None

let callee i =
  let c = Llvm.operand i (Llvm.num_operands i - 1) in
  match Llvm.classify_value c with Llvm.ValueKind.Function -> Some c | _ -> None

let is_call i =
  match Llvm.classify_value i with Llvm.ValueKind.Instruction Llvm.Opcode.Call -> true | _ -> false

let noreturn f =
  let kind = Llvm.enum_attr_kind "noreturn" in
  Array.exists
    (fun a -> match Llvm.repr_of_attr a with Llvm.AttrRepr.Enum (k, _) -> k = kind | _ -> false)
    (Llvm.function_attrs f Llvm.AttrIndex.Function)

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

let run m =
  match limit () with
  | None -> ()
  | Some n ->
      let looped = Option.value (loops ()) ~default:(-1) in
      (* A defined function's size, when it is a leaf with no cycle (or,
         with ZANE_LOOP_INLINE_LOOPS, one with a cycle, negated). *)
      let sizes = Hashtbl.create 64 in
      let size f =
        match Hashtbl.find_opt sizes f with
        | Some s -> s
        | None ->
            let s =
              let loops = Hashtbl.length (cyclic f) > 0 in
              if Llvm.is_declaration f || not (ours f) || (loops && looped < 0) then None
              else
                try
                  Some
                    (Llvm.fold_left_blocks
                       (fun acc bb ->
                         Llvm.fold_left_instrs
                           (fun acc i ->
                             if is_call i then
                               match callee i with
                               | Some c when String.starts_with ~prefix:"llvm." (Llvm.value_name c) -> acc + 1
                               | Some c when noreturn c -> acc + 1
                               | Some c when looped >= 0 && List.mem (Llvm.value_name c) pushes -> acc + 1
                               | _ -> raise Exit
                             else acc + 1)
                           acc bb)
                       0 f
                    |> fun s -> if loops then -s else s)
                with Exit -> None
            in
            Hashtbl.replace sizes f s;
            s
      in
      let ctx = Llvm.module_context m in
      let always = Llvm.create_enum_attr ctx "alwaysinline" 0L in
      let debug = Sys.getenv_opt "ZANE_LOOP_INLINE_DEBUG" = Some "1" in
      Llvm.iter_functions
        (fun f ->
          if (not (Llvm.is_declaration f)) && ours f then begin
            let inside = cyclic f in
            Llvm.iter_blocks
              (fun bb ->
                if Hashtbl.mem inside bb then
                  Llvm.iter_instrs
                    (fun i ->
                      if is_call i then
                        match callee i with
                        | Some c when c != f -> (
                            match size c with
                            | Some s when (s >= 0 && s <= n) || (s < 0 && -s <= looped) ->
                                if debug then
                                  prerr_endline (Printf.sprintf "loop-inline: %s -> %s: %d" (Llvm.value_name f) (Llvm.value_name c) s);
                                Llvm.add_call_site_attr i always Llvm.AttrIndex.Function
                            | s ->
                                if debug then
                                  prerr_endline
                                    (Printf.sprintf "loop-inline left: %s -> %s: %s" (Llvm.value_name f) (Llvm.value_name c)
                                       (match s with
                                       | Some s when s < 0 -> "loops " ^ string_of_int (-s)
                                | Some s -> string_of_int s
                                       | None when Llvm.is_declaration c -> "declared"
                                       | None when not (ours c) -> "not ours"
                                       | None when Hashtbl.length (cyclic c) > 0 -> "loops"
                                       | None -> "calls")))
                        | _ -> ())
                    bb)
              f
          end)
        m

let again =
  "always-inline,function(sroa,early-cse<memssa>,instcombine<no-verify-fixpoint>,simplifycfg,gvn,loop-mssa(licm<allowspeculation>),simplifycfg)"
