(* The LLVM types of the CGT's types, and how a value of each crosses a
   call (docs/design/lowering.md L2, §9): the first part of Emit, which
   includes it. *)

open Cgt.Nodes
open Loop_shapes
open Call_pieces
open Llvm_extra

(* How a value of a type crosses a call (docs/design/lowering.md §9): as
   itself, in as many registers as it has pieces; as the address of a slot
   that holds it; or, with packing, as that many 8-byte words. *)
type passing = Itself | Address | Words of int

(* A function's signature as it crosses: how each parameter that is not
   `Unit` passes, in order, and how the result comes back. *)
type abi = { params : (Ty.t * passing) list; ret : Ty.t * passing }

type env = {
  ctx : Llvm.llcontext;
  m : Llvm.llmodule;
  ptr : Llvm.lltype;
  i64 : Llvm.lltype;
  funcs : (string, Llvm.llvalue * Llvm.lltype) Hashtbl.t;
  (* How each of the program's functions is called, by symbol. *)
  abis : (string, abi) Hashtbl.t;
  (* The thunks of calls into C, by symbol, with whether each argument is
     a function value, which C takes as its lambda's C entry
     (docs/design/ffi.md F11). *)
  entries : (string, bool list) Hashtbl.t;
  (* How many registers a value may take and still pass as itself, from
     the target (see [registers]), whether small aggregates are packed into
     words, and how each type passes, worked out once per type. *)
  registers : int;
  pack : bool;
  passings : (Ty.t, passing) Hashtbl.t;
  (* The same for a result (see [results]). *)
  results : int * int;
  returnings : (Ty.t, passing) Hashtbl.t;
  globals : (string, Llvm.llvalue) Hashtbl.t;
  (* The walks of each layout the program names that lists a position. *)
  mutable walks : Walks.known option;
  (* The type-based alias tags of a handle's fields and of any other
     scalar (see [access]). *)
  handle_tag : Llvm.llvalue;
  value_tag : Llvm.llvalue;
  (* Whether a loop over elements is emitted twice (see [versioned]), which
     only the passes of an optimized build use. *)
  version : bool;
}

(* ---------------------------------------------------------------------- *)
(* Types                                                                  *)
(* ---------------------------------------------------------------------- *)

(* A value this many bytes or larger is moved as memory (Big_moves). *)
let large = 4096

let size_align = Ty.size_align
let words = Ty.words

(* Packed types (Ty.Packed): the address of a place inside a
   packed type is named [unaligned_name], and so is one inside such a
   place, so that once a function is emitted every load and store through
   one is marked as at any byte. *)
let unaligned_name = "packed"

let is_unaligned v =
  match Llvm.classify_value v with
  | Llvm.ValueKind.Instruction Llvm.Opcode.GetElementPtr -> String.starts_with ~prefix:unaligned_name (Llvm.value_name v)
  | _ -> false

let unaligned fn =
  Llvm.iter_blocks
    (Llvm.iter_instrs (fun i ->
         match Llvm.instr_opcode i with
         | Llvm.Opcode.Load when is_unaligned (Llvm.operand i 0) -> Llvm.set_alignment 1 i
         | Llvm.Opcode.Store when is_unaligned (Llvm.operand i 1) -> Llvm.set_alignment 1 i
         | _ -> ()))
    fn

let rec lltype env (t : Ty.t) =
  match t with
  | Ty.Void -> Llvm.void_type env.ctx
  | Ty.I1 -> Llvm.i1_type env.ctx
  | Ty.I32 -> Llvm.i32_type env.ctx
  | Ty.I64 -> env.i64
  | Ty.F32 -> Llvm.float_type env.ctx
  | Ty.F64 -> Llvm.double_type env.ctx
  | Ty.Handle -> Llvm.struct_type env.ctx [| env.ptr; env.i64; env.i64 |]
  | Ty.Handle16 -> List_handle.header env.ctx
  | Ty.Ptr -> env.ptr
  | Ty.Ref | Ty.Box32 -> Llvm.i32_type env.ctx
  | Ty.Struct ts -> Llvm.struct_type env.ctx (Array.of_list (List.map (stored env) ts))
  | Ty.Sum ts when Option.is_some (Ty.byte_niche ts) -> (
      (* A byte niche (Ty.byte_niche): the payload's layout, its spare
         [Bool] a byte, which holds the other cases' values. *)
      match Ty.byte_niche ts with
      | Some { case; path = Some path; _ } -> with_byte env (List.nth ts case) path
      | Some { case; path = None; _ } -> lltype env (List.nth ts case)
      | None -> Llvm.void_type env.ctx)
  | Ty.Sum ts when Ty.niche ts -> Llvm.struct_type env.ctx [| Llvm.i32_type env.ctx |]
  | Ty.Sum ts -> (
      let tag = Llvm.i32_type env.ctx in
      match words ts with
      | 0 -> Llvm.struct_type env.ctx [| tag |]
      | n -> Llvm.struct_type env.ctx [| tag; array_type env.i64 n |])
  | Ty.Array (t, n) -> array_type (stored env t) n
  | Ty.Packed (Ty.Struct ts) -> Llvm.packed_struct_type env.ctx (Array.of_list (List.map (stored env) ts))
  | Ty.Packed (Ty.Sum ts) -> (
      let tag = Llvm.i8_type env.ctx in
      match Ty.room ts with
      | 0 -> Llvm.packed_struct_type env.ctx [| tag |]
      | n ->
          (* The room as words, then the 4, 2 and 1 bytes left, so a payload
             crosses calls and moves in as few pieces as its bytes allow. *)
          let pieces =
            List.init (n / 8) (fun _ -> env.i64)
            @ List.filter_map
                (fun (bytes, t) -> if n land bytes <> 0 then Some t else None)
                [ (4, Llvm.i32_type env.ctx); (2, Llvm.i16_type env.ctx); (1, Llvm.i8_type env.ctx) ]
          in
          let room = match pieces with [ t ] -> t | ts -> Llvm.packed_struct_type env.ctx (Array.of_list ts) in
          Llvm.packed_struct_type env.ctx [| tag; room |])
  | Ty.Packed t -> lltype env t

(* [t]'s layout with the [Bool] at [path] a byte. *)
and with_byte env t path =
  match (path, t) with
  | [], Ty.I1 -> Llvm.i8_type env.ctx
  | i :: rest, (Ty.Struct ts | Ty.Packed (Ty.Struct ts)) ->
      let ms = Array.of_list (List.mapi (fun j m -> if j = i then with_byte env m rest else stored env m) ts) in
      (match t with Ty.Packed _ -> Llvm.packed_struct_type env.ctx ms | _ -> Llvm.struct_type env.ctx ms)
  | _ :: rest, Ty.Array (e, n) -> array_type (with_byte env e rest) n
  | _ -> lltype env t

(* A `Unit` member takes no room, but keeps its index. *)
and stored env t = if t = Ty.Void then Llvm.struct_type env.ctx [||] else lltype env t

(* ---------------------------------------------------------------------- *)
(* How a value crosses a call                                             *)
(* ---------------------------------------------------------------------- *)

(* How a value of type [t] crosses a call: as itself when it takes no more
   registers than [env.registers], and by the address of a slot otherwise.
   With [env.pack], an aggregate that fits in that many 8-byte words passes
   as them instead, every word an integer, as clang passes a small C
   struct. Fixed by the type, so every call site and every callee agree,
   and a function value's call too. *)
let passing env (t : Ty.t) =
  match Hashtbl.find_opt env.passings t with
  | Some p -> p
  | None ->
      let p =
        let size = fst (size_align t) in
        let words = (size + 7) / 8 in
        if env.pack && aggregate t && size > 0 then if words <= env.registers then Words words else Address
        else if pieces t <= env.registers then Itself
        else Address
      in
      Hashtbl.replace env.passings t p;
      p

(* How a result of type [t] comes back from a call: as [passing] decides
   for an argument, but within [env.results], so a result may take more
   registers than an argument. A larger one is written through an `sret`
   pointer to a slot of the caller's. *)
let returning env (t : Ty.t) =
  match Hashtbl.find_opt env.returnings t with
  | Some p -> p
  | None ->
      let most, most_floats = env.results in
      let p =
        let size = fst (size_align t) in
        let words = (size + 7) / 8 in
        if env.pack && aggregate t && size > 0 then if words <= most then Words words else Address
        else if pieces t <= most && floats t <= most_floats then Itself
        else Address
      in
      Hashtbl.replace env.returnings t p;
      p

(* The LLVM type [n] words travel as: one `i64`, or a struct of them. *)
let words_type env n = if n = 1 then env.i64 else Llvm.struct_type env.ctx (Array.make n env.i64)

(* A signature as it crosses (see [passing]). `Unit` has no storage, so a
   `Unit` parameter passes nothing. *)
let abi env params ret =
  let kept = List.filter (fun t -> t <> Ty.Void) params in
  let crossing t = if t = Ty.Void then Itself else returning env t in
  { params = List.map (fun t -> (t, passing env t)) kept; ret = (ret, crossing ret) }

(* The LLVM function type of [a]: a result passed by address is written
   through a leading pointer, and returns nothing. *)
let abi_type env a =
  let ret, ret_passing = a.ret in
  let result, leading =
    match ret_passing with
    | Itself -> (lltype env ret, [])
    | Address -> (Llvm.void_type env.ctx, [ env.ptr ])
    | Words n -> (words_type env n, [])
  in
  let param (t, p) =
    match p with Itself -> [ lltype env t ] | Address -> [ env.ptr ] | Words n -> List.init n (fun _ -> env.i64)
  in
  Llvm.function_type result (Array.of_list (leading @ List.concat_map param a.params))

let fn_type env params ret = abi_type env (abi env params ret)

(* What a signature tells LLVM, as attributes on each LLVM parameter, by
   index. A parameter passed by address is a borrow (memory.md §2.9), and
   nothing in the call writes what it borrows (§2.9.1), so it is `readonly`
   and `noalias`, and dereferenceable for its whole size: the optimizer may
   take the value behind it for a private copy. It claims no alignment,
   since what it borrows may be a member at any byte of a packed value
   (Ty.tight); the `sret` slot is the caller's own, at its alignment. It is not
   `nocapture`, since a call the callee spawns may hold the address for as
   long as it runs. A result passed by address is written through an
   `sret` pointer to a fresh slot of the caller's, which nothing else
   names, so that one is `noalias` too. *)
let abi_attrs env a =
  let enum name v = Llvm.create_enum_attr env.ctx name v in
  let aligned t = enum "align" (Int64.of_int (snd (size_align t))) in
  let ret, ret_passing = a.ret in
  let leading =
    match ret_passing with
    | Address -> [ [ type_attr env.ctx "sret" (lltype env ret); enum "noalias" 0L; aligned ret ] ]
    | Itself | Words _ -> []
  in
  let param (t, p) =
    match p with
    | Itself -> [ [] ]
    | Words n -> List.init n (fun _ -> [])
    | Address ->
        [
          [
            enum "readonly" 0L;
            enum "noalias" 0L;
            enum "dereferenceable" (Int64.of_int (fst (size_align t)));
          ];
        ]
  in
  List.mapi (fun i attrs -> (i, attrs)) (leading @ List.concat_map param a.params)

let declare_abi env f a =
  List.iter
    (fun (i, attrs) -> List.iter (fun at -> Llvm.add_function_attr f at (Llvm.AttrIndex.Param i)) attrs)
    (abi_attrs env a)

(* What a function's [places] (Func) tell LLVM: each is the address of a
   whole slot that outlives the call, so it is `nonnull` and
   dereferenceable for the slot's size. It claims no alignment: the slot
   may be a member at any byte of a packed value (Ty.tight). That lets the optimizer read
   through it ahead of a branch, as it hoists a list's length and storage
   out of a loop that checks its indices. Nothing more is promised: the
   function may write the slot, and another parameter may name it too. *)
let declare_places env fn (f : Func.t) a =
  let enum name v = Llvm.create_enum_attr env.ctx name v in
  let kept = List.filter (fun (_, t) -> t <> Ty.Void) f.Func.params in
  let width = function Itself | Address -> 1 | Words n -> n in
  let first = if snd a.ret = Address then 1 else 0 in
  ignore
    (List.fold_left2
       (fun i (id, _) (_, passing) ->
         (match List.assoc_opt id f.Func.places with
         | Some t when passing = Itself && fst (size_align t) > 0 ->
             let size = fst (size_align t) in
             List.iter
               (fun at -> Llvm.add_function_attr fn at (Llvm.AttrIndex.Param i))
               [ enum "nonnull" 0L; enum "dereferenceable" (Int64.of_int size) ]
         | _ -> ());
         i + width passing)
       first kept a.params)
