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

   So a call is marked `alwaysinline` when it is in a cycle of its
   function's blocks and the callee is a leaf: defined here, and calling
   only functions that do not return (the out-of-range stop), LLVM's
   intrinsics, and other such leaves, with at most N instructions in all,
   as emitted (before any pass). Runs on the module as emitted. *)

let limit () =
  match Sys.getenv_opt "ZANE_LOOP_INLINE" with Some n -> int_of_string_opt n | None -> None

let on () = limit () <> None

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

let run m =
  match limit () with
  | None -> ()
  | Some n ->
      let ctx = Llvm.module_context m in
      (* A defined function's size with every callee it would take, or None
         when it is not a leaf. *)
      let sizes = Hashtbl.create 64 in
      let rec size f =
        match Hashtbl.find_opt sizes f with
        | Some s -> s
        | None ->
            Hashtbl.replace sizes f None;
            let s =
              if Llvm.is_declaration f then None
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
                               | Some c -> ( match size c with Some s -> acc + s | None -> raise Exit)
                               | None -> raise Exit
                             else acc + 1)
                           acc bb)
                       0 f)
                with Exit -> None
            in
            Hashtbl.replace sizes f s;
            s
      in
      let always = Llvm.create_enum_attr ctx "alwaysinline" 0L in
      Llvm.iter_functions
        (fun f ->
          if not (Llvm.is_declaration f) then begin
            let inside = cyclic f in
            Llvm.iter_blocks
              (fun bb ->
                if Hashtbl.mem inside bb then
                  Llvm.iter_instrs
                    (fun i ->
                      if is_call i then
                        match callee i with
                        | Some c when c != f && not (Llvm.is_declaration c) -> (
                            let s = size c in
                            if Sys.getenv_opt "ZANE_LOOP_INLINE_DEBUG" = Some "1" then
                              prerr_endline
                                (Printf.sprintf "loop-inline: %s -> %s: %s" (Llvm.value_name f) (Llvm.value_name c)
                                   (match s with Some s -> string_of_int s | None -> "not a leaf"));
                            match s with
                            | Some s when s <= n -> Llvm.add_call_site_attr i always Llvm.AttrIndex.Function
                            | _ -> ())
                        | _ -> ())
                    bb)
              f
          end)
        m
