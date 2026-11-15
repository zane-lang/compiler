(* EXPERIMENT (LangArena zane-vs-goose; on with ZANE_ELEM_TBAA=1): a
   scalar read or written inside a list's element tagged by the list's
   stride as well as by its size.

   With ZANE_SIZED_TBAA a scalar's tag says only its size (Emit.access),
   so a push onto a `List<I32>` (an `i32` store into its block) may, as
   LLVM sees it, write the `I32` members of a `List<Cell>`'s elements: a
   loop that pushes onto a stack while it reads a cell's neighbors reloads
   each neighbor after every push and checks its index against the count
   again (Maze::Generator's `dig`). A list owns its block, so two lists'
   blocks are apart while both live, and a block one list gives back holds
   another list's elements only after it is taken again through the
   runtime, as a handle and a scalar's storage are told apart already
   (Emit.tags). So lists whose elements differ in stride never share
   storage, and an access found to be inside an element of a list of
   stride [s] takes a child of its sized tag for [s]: it aliases every
   access the sized tag does except those of another stride's elements.

   Emit marks the address each `List_at` and `List_push` gives with
   `!zane.elem` (its constant stride). An access's address is traced back
   through GEPs (a member, an `Array` element inside it), phis and selects,
   and loads from a slot that is only loaded and stored, every store of
   which is traced the same way, to marked addresses of one stride. An
   address traced to anything else keeps the sized tag. Runs on the module
   as emitted, before LLVM's passes, while the addresses are as Emit made
   them.

   A push that finds its list full calls the runtime, which LLVM takes to
   write anything, so a cell's members read before the push are read
   again after it. The runtime's push writes the list's handle, its block
   (or a new one) and the regions' records, which the program reaches only
   untagged; no other list's elements. So each traced access is also in a
   scope of its stride (`!alias.scope`) and apart from every other
   stride's scope (`!noalias`), and a call of `zane_list_push` or
   `zane_list_reserve` of stride [s] is apart from every scope but [s]'s. *)

let on () = Sys.getenv_opt "ZANE_ELEM_TBAA" = Some "1"

let kind ctx = Llvm.mdkind_id ctx "zane.elem"

(* [v], an element's address in a list of stride [stride], marked so. *)
let mark ctx v stride =
  if on () then
    match (Llvm.classify_value v, Llvm.int64_of_const stride) with
    | Llvm.ValueKind.Instruction _, Some s when s > 0L ->
        Llvm.set_metadata v (kind ctx) (Llvm.mdnode ctx [| Llvm.const_of_int64 (Llvm.i64_type ctx) s true |])
    | _ -> ()

(* What a trace finds: nothing yet (a cycle back to where it started), one
   stride, or something else. *)
type found = Open | Stride of int64 | Other

let join a b =
  match (a, b) with
  | Open, x | x, Open -> x
  | Stride x, Stride y when x = y -> a
  | _ -> Other

let marked ctx v =
  match Llvm.metadata v (kind ctx) with
  | Some md -> (
      match Llvm.get_mdnode_operands md with [| c |] -> Llvm.int64_of_const c | _ -> None)
  | None -> None

let is_alloca v =
  match Llvm.classify_value v with Llvm.ValueKind.Instruction Llvm.Opcode.Alloca -> true | _ -> false

(* The values stored into [slot], when it is only loaded and stored. *)
let stored slot =
  try
    Some
      (Llvm.fold_left_uses
         (fun acc u ->
           let user = Llvm.user u in
           match Llvm.classify_value user with
           | Llvm.ValueKind.Instruction Llvm.Opcode.Load -> acc
           | Llvm.ValueKind.Instruction Llvm.Opcode.Store when Llvm.operand user 1 == slot && Llvm.operand user 0 != slot ->
               Llvm.operand user 0 :: acc
           | _ -> raise Exit)
         [] slot)
  with Exit -> None

let trace ctx v =
  let seen = Hashtbl.create 8 in
  let rec go v =
    match marked ctx v with
    | Some s -> Stride s
    | None -> (
        match Llvm.classify_value v with
        | Llvm.ValueKind.Instruction Llvm.Opcode.GetElementPtr -> go (Llvm.operand v 0)
        | Llvm.ValueKind.Instruction Llvm.Opcode.Select -> join (go (Llvm.operand v 1)) (go (Llvm.operand v 2))
        | Llvm.ValueKind.Instruction Llvm.Opcode.PHI ->
            if Hashtbl.mem seen v then Open
            else begin
              Hashtbl.replace seen v ();
              List.fold_left (fun acc (x, _) -> if acc = Other then acc else join acc (go x)) Open (Llvm.incoming v)
            end
        | Llvm.ValueKind.Instruction Llvm.Opcode.Load ->
            let slot = Llvm.operand v 0 in
            if not (is_alloca slot) then Other
            else if Hashtbl.mem seen slot then Open
            else begin
              Hashtbl.replace seen slot ();
              match stored slot with
              | Some values -> List.fold_left (fun acc x -> if acc = Other then acc else join acc (go x)) Open values
              | None -> Other
            end
        | _ -> Other)
  in
  match go v with Stride s -> Some s | Open | Other -> None

let sized = [ "zane byte"; "zane word4"; "zane word8" ]

(* The sized type node of an access tag, when it is one. *)
let sized_node tag =
  match Llvm.get_mdnode_operands tag with
  | [| node; _; _ |] -> (
      match Llvm.get_mdnode_operands node with
      | [| name; _; _ |] -> (
          match Llvm.get_mdstring name with Some n when List.mem n sized -> Some (n, node) | _ -> None)
      | _ -> None)
  | _ -> None

(* The strides marked anywhere in [m]. *)
let strides ctx m =
  let found = Hashtbl.create 8 in
  Llvm.iter_functions
    (fun f ->
      Llvm.iter_blocks
        (fun bb -> Llvm.iter_instrs (fun i -> Option.iter (fun s -> Hashtbl.replace found s ()) (marked ctx i)) bb)
        f)
    m;
  List.sort compare (Hashtbl.fold (fun s () acc -> s :: acc) found [])

(* The runtime's pushes, which grow the list given them and write no other
   list's elements: their stride is their last argument. *)
let pushes = [ "zane_list_push"; "zane_list_reserve" ]

let func ctx scopes f =
  let tbaa = Llvm.mdkind_id ctx "tbaa" in
  let scope_kind = Llvm.mdkind_id ctx "alias.scope" and noalias_kind = Llvm.mdkind_id ctx "noalias" in
  let zero = Llvm.const_int (Llvm.i64_type ctx) 0 in
  let others s = Llvm.mdnode ctx (Array.of_list (List.filter_map (fun (t, n) -> if t = s then None else Some n) scopes)) in
  let scoped i s =
    match List.assoc_opt s scopes with
    | Some n ->
        Llvm.set_metadata i scope_kind (Llvm.mdnode ctx [| n |]);
        if List.length scopes > 1 then Llvm.set_metadata i noalias_kind (others s)
    | None -> ()
  in
  Llvm.iter_blocks
    (fun bb ->
      Llvm.iter_instrs
        (fun i ->
          let address =
            match Llvm.classify_value i with
            | Llvm.ValueKind.Instruction Llvm.Opcode.Load -> Some (Llvm.operand i 0)
            | Llvm.ValueKind.Instruction Llvm.Opcode.Store -> Some (Llvm.operand i 1)
            | _ -> None
          in
          (match Llvm.classify_value i with
          | Llvm.ValueKind.Instruction Llvm.Opcode.Call when List.length scopes > 1 -> (
              let callee = Llvm.operand i (Llvm.num_operands i - 1) in
              if List.mem (Llvm.value_name callee) pushes then
                match Llvm.int64_of_const (Llvm.operand i 1) with
                | Some s when List.mem_assoc s scopes -> Llvm.set_metadata i noalias_kind (others s)
                | _ -> ())
          | _ -> ());
          match (address, Llvm.metadata i tbaa) with
          | Some p, Some tag -> (
              match sized_node tag with
              | Some (name, parent) -> (
                  match trace ctx p with
                  | Some s ->
                      let node = Llvm.mdnode ctx [| Llvm.mdstring ctx (Printf.sprintf "%s s%Ld" name s); parent; zero |] in
                      Llvm.set_metadata i tbaa (Llvm.mdnode ctx [| node; node; zero |]);
                      scoped i s
                  | None -> ())
              | None -> ())
          | _ -> ())
        bb)
    f

let run m =
  if on () then
    let ctx = Llvm.module_context m in
    let domain = Llvm.mdnode ctx [| Llvm.mdstring ctx "zane elements" |] in
    let scopes =
      List.map
        (fun s -> (s, Llvm.mdnode ctx [| Llvm.mdstring ctx (Printf.sprintf "zane elements s%Ld" s); domain |]))
        (strides ctx m)
    in
    Llvm.iter_functions (fun f -> if not (Llvm.is_declaration f) then func ctx scopes f) m
