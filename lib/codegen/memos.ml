(* Remembered functions' dispatchers (docs/design/memoization.md), emitted
   once the program's functions are (Codegen.program). *)

open Cgt.Nodes
open Emit

(* A remembered function's dispatcher (Cgt.Memo). Its table is
   direct-mapped: each entry is a tag, the argument words, the result words
   and the work the result took, found by a multiplicative hash of the
   arguments, and a miss overwrites whatever entry was there. The work is
   what the result's calls would run without a table, counted from below
   in [zane.memo.calls]: each miss adds its function's [Cgt.Memo.cheapest],
   and each hit the work its entry kept; an entry keeps at most 2^40. The
   state charges each lookup the function's [Cgt.Memo.charge] and credits
   each hit with the work it saved, at [Cgt.Memo.credit], never going below
   zero; once it reaches [memo_limit] the dispatcher stops looking and
   calls the plain copy, which looks nothing up. A function whose arguments rarely repeat, or whose repeats
   save less than a lookup costs, pays for a bounded number of lookups and
   then runs as it would have. The table starts on a cache line, so where
   it lands in the binary does not decide which entries straddle two. *)
let memo_limit = Cgt.Memo.limit
let memo_bytes = 65536
let memo_most_entries = 4096

let memo env (m : Cgt.Memo.t) =
  let f = m.Cgt.Memo.func in
  let fn, fty = Hashtbl.find env.funcs f.Func.symbol in
  let a = Hashtbl.find env.abis f.Func.symbol in
  let body, bty = Hashtbl.find env.funcs m.Cgt.Memo.body in
  let plain, pty = Hashtbl.find env.funcs m.Cgt.Memo.plain in
  let i64 = env.i64 and ctx = env.ctx in
  let b = Llvm.builder_at_end ctx (Llvm.entry_block fn) in
  let calling fn target ty =
    let site = Llvm.build_call ty target (Llvm.params fn) "" b in
    List.iter
      (fun (i, attrs) -> List.iter (fun at -> Llvm.add_call_site_attr site at (Llvm.AttrIndex.Param i)) attrs)
      (abi_attrs env a);
    site
  in
  let ret, ret_passing = a.ret in
  let finish site = ignore (if ret_passing = Address || ret = Ty.Void then Llvm.build_ret_void b else Llvm.build_ret site b) in
  let state = Hashtbl.find env.globals (Cgt.Memo.state_symbol f.Func.symbol) in
  (* The gate, under the function's own symbol, is inlined into every
     caller, so a caller whose dispatcher has stopped looking calls the
     plain copy directly, and LLVM may inline and fold it there as it would
     the function itself. The lookup is a function of its own. *)
  let lookup = Llvm.define_function (f.Func.symbol ^ ".lookup") fty env.m in
  Llvm.set_linkage Llvm.Linkage.Internal lookup;
  declare_abi env lookup a;
  Llvm.add_function_attr lookup (Llvm.create_enum_attr ctx "noinline" 0L) Llvm.AttrIndex.Function;
  Llvm.add_function_attr fn (Llvm.create_enum_attr ctx "alwaysinline" 0L) Llvm.AttrIndex.Function;
  let st = Llvm.build_load i64 state "" b in
  let plain_b = Llvm.append_block ctx "" fn and look = Llvm.append_block ctx "" fn in
  ignore (Llvm.build_cond_br (Llvm.build_icmp Llvm.Icmp.Sge st (Llvm.const_int i64 memo_limit) "" b) plain_b look b);
  Llvm.position_at_end plain_b b;
  let site = calling fn plain pty in
  Llvm.set_tail_call true site;
  finish site;
  Llvm.position_at_end look b;
  let site = calling fn lookup fty in
  Llvm.set_tail_call true site;
  finish site;
  let fn = lookup in
  Llvm.position_at_end (Llvm.entry_block fn) b;
  (* A value is remembered as the 8-byte words of its bytes, copied into a
     zeroed buffer. The bytes a value leaves undefined, its padding and the
     room past a smaller case's payload, are frozen, so a comparison of
     them is a comparison of some fixed bits: at worst a miss, never a hit
     LLVM made up. *)
  let buffer n =
    let top = Llvm.builder_at ctx (Llvm.instr_begin (Llvm.entry_block fn)) in
    let p = Llvm.build_alloca (Llvm.array_type i64 (max n 1)) "" top in
    zero env b p (8 * n);
    p
  in
  let word p i = Llvm.build_in_bounds_gep i64 p [| Llvm.const_int i64 i |] "" b in
  let read p n = List.init n (fun i -> Llvm.build_freeze (Llvm.build_load i64 (word p i) "" b) "" b) in
  let copy dst src size =
    let i1 = Llvm.i1_type ctx in
    let t = Llvm.function_type (Llvm.void_type ctx) [| env.ptr; env.ptr; i64; i1 |] in
    let name = "llvm.memcpy.p0.p0.i64" in
    let f = match Llvm.lookup_function name env.m with Some f -> f | None -> Llvm.declare_function name t env.m in
    ignore (Llvm.build_call t f [| dst; src; Llvm.const_int i64 size; Llvm.const_int i1 0 |] "" b)
  in
  let words_of t = (fst (size_align t) + 7) / 8 in
  (* A value of scalars only, a struct's included, is taken apart into
     words directly, one word to each scalar, and needs no buffer. *)
  let rec scalars (t : Ty.t) =
    match t with
    | Ty.Void | Ty.I1 | Ty.I32 | Ty.I64 | Ty.F32 | Ty.F64 -> true
    | Ty.Struct ts -> List.for_all scalars ts
    | _ -> false
  in
  let rec flatten (t : Ty.t) v =
    match t with
    | Ty.Void -> []
    | Ty.I64 -> [ Llvm.build_freeze v "" b ]
    | Ty.I32 | Ty.I1 -> [ Llvm.build_zext (Llvm.build_freeze v "" b) i64 "" b ]
    | Ty.F64 -> [ Llvm.build_bitcast (Llvm.build_freeze v "" b) i64 "" b ]
    | Ty.F32 -> [ Llvm.build_zext (Llvm.build_bitcast (Llvm.build_freeze v "" b) (Llvm.i32_type ctx) "" b) i64 "" b ]
    | Ty.Struct ts -> List.concat (List.mapi (fun i t -> flatten t (Llvm.build_extractvalue v i "" b)) ts)
    | _ -> Diagnostic.bug "codegen: a remembered value that is not scalars"
  in
  let rec count (t : Ty.t) = match t with Ty.Void -> 0 | Ty.Struct ts -> List.fold_left (fun n t -> n + count t) 0 ts | _ -> 1 in
  let rec rebuild (t : Ty.t) ws =
    match (t, ws) with
    | Ty.Void, ws -> (Llvm.undef (stored env t), ws)
    | Ty.I64, w :: ws -> (w, ws)
    | (Ty.I32 | Ty.I1), w :: ws -> (Llvm.build_trunc w (lltype env t) "" b, ws)
    | Ty.F64, w :: ws -> (Llvm.build_bitcast w (lltype env t) "" b, ws)
    | Ty.F32, w :: ws -> (Llvm.build_bitcast (Llvm.build_trunc w (Llvm.i32_type ctx) "" b) (lltype env t) "" b, ws)
    | Ty.Struct ts, ws ->
        List.fold_left
          (fun (v, ws) (i, t) ->
            let x, ws = rebuild t ws in
            (Llvm.build_insertvalue v x i "" b, ws))
          (Llvm.undef (lltype env t), ws)
          (List.mapi (fun i t -> (i, t)) ts)
    | _ -> Diagnostic.bug "codegen: a remembered value that is not scalars"
  in
  let of_value t v =
    if scalars t then flatten t v
    else
      let n = words_of t in
      let p = buffer n in
      ignore (Llvm.build_store v p b);
      read p n
  in
  let of_place t src =
    if scalars t then flatten t (Llvm.build_load (lltype env t) src "" b)
    else
      let n = words_of t in
      let p = buffer n in
      copy p src (fst (size_align t));
      read p n
  in
  let next = ref (if ret_passing = Address then 1 else 0) in
  let param () =
    let p = Llvm.param fn !next in
    incr next;
    p
  in
  let keys =
    List.concat_map
      (fun (t, p) ->
        match p with
        | Itself -> of_value t (param ())
        | Words n -> List.init n (fun _ -> Llvm.build_freeze (param ()) "" b)
        | Address -> of_place t (param ()))
      a.params
  in
  let result_words = match ret_passing with Words n -> n | (Itself | Address) when scalars ret -> count ret | Itself | Address -> words_of ret in
  let width = 1 + List.length keys + result_words + 1 in
  let weight = width - 1 in
  let entries =
    let rec down n = if n > 1 && (n * width * 8 > memo_bytes || n > memo_most_entries) then down (n / 2) else n in
    down memo_most_entries
  in
  let bits = let rec log n = if n <= 1 then 0 else 1 + log (n / 2) in log entries in
  let entry_ty = Llvm.array_type i64 width in
  let table = Llvm.define_global (f.Func.symbol ^ ".memo.table") (Llvm.const_null (Llvm.array_type entry_ty entries)) env.m in
  Llvm.set_linkage Llvm.Linkage.Internal table;
  Llvm.set_alignment Abi.line table;
  let st = Llvm.build_load i64 state "" b in
  let k = Llvm.const_of_int64 i64 (-7046029254386353131L) false in
  let h = List.fold_left (fun h w -> Llvm.build_mul (Llvm.build_xor h w "" b) k "" b) (Llvm.const_int i64 0) keys in
  let h = Llvm.build_mul (Llvm.build_xor h (Llvm.build_lshr h (Llvm.const_int i64 31) "" b) "" b) k "" b in
  let index = if bits = 0 then Llvm.const_int i64 0 else Llvm.build_lshr h (Llvm.const_int i64 (64 - bits)) "" b in
  let tag = Llvm.build_or h (Llvm.const_int i64 1) "" b in
  let at i = Llvm.build_in_bounds_gep (Llvm.array_type entry_ty entries) table [| Llvm.const_int i64 0; index; Llvm.const_int i64 i |] "" b in
  let found =
    List.fold_left
      (fun acc (i, w) -> Llvm.build_and acc (Llvm.build_icmp Llvm.Icmp.Eq (Llvm.build_load i64 (at (i + 1)) "" b) w "" b) "" b)
      (Llvm.build_icmp Llvm.Icmp.Eq (Llvm.build_load i64 (at 0) "" b) tag "" b)
      (List.mapi (fun i w -> (i, w)) keys)
  in
  let calls =
    match Llvm.lookup_global "zane.memo.calls" env.m with
    | Some g -> g
    | None ->
        let g = Llvm.define_global "zane.memo.calls" (Llvm.const_int i64 0) env.m in
        Llvm.set_linkage Llvm.Linkage.Internal g;
        g
  in
  let hit = Llvm.append_block ctx "" fn and miss = Llvm.append_block ctx "" fn in
  ignore (Llvm.build_cond_br found hit miss b);
  (* A hit: the work the result took added to the count of the miss it
     runs in, the state credited with it, and the result's words given
     back as it returns. *)
  Llvm.position_at_end hit b;
  let took = Llvm.build_load i64 (at weight) "" b in
  ignore (Llvm.build_store (Llvm.build_add (Llvm.build_load i64 calls "" b) took "" b) calls b);
  let saved =
    Llvm.build_lshr (Llvm.build_mul took (Llvm.const_int i64 m.Cgt.Memo.credit) "" b) (Llvm.const_int i64 Cgt.Memo.credit_shift) "" b
  in
  let down = Llvm.build_sub (Llvm.build_add st (Llvm.const_int i64 m.Cgt.Memo.charge) "" b) saved "" b in
  let floor = Llvm.build_select (Llvm.build_icmp Llvm.Icmp.Slt down (Llvm.const_int i64 0) "" b) (Llvm.const_int i64 0) down "" b in
  ignore (Llvm.build_store floor state b);
  let kept = List.init result_words (fun i -> Llvm.build_load i64 (at (1 + List.length keys + i)) "" b) in
  (match ret_passing with
  | Words 1 -> ignore (Llvm.build_ret (List.hd kept) b)
  | Words n ->
      let v, _ = List.fold_left (fun (v, i) w -> (Llvm.build_insertvalue v w i "" b, i + 1)) (Llvm.undef (words_type env n), 0) kept in
      ignore (Llvm.build_ret v b)
  | (Itself | Address) when scalars ret ->
      let v = fst (rebuild ret kept) in
      if ret_passing = Address then (
        ignore (Llvm.build_store v (Llvm.param fn 0) b);
        ignore (Llvm.build_ret_void b))
      else ignore (Llvm.build_ret v b)
  | Itself | Address ->
      let p = buffer result_words in
      List.iteri (fun i w -> ignore (Llvm.build_store w (word p i) b)) kept;
      if ret_passing = Address then (
        copy (Llvm.param fn 0) p (fst (size_align ret));
        ignore (Llvm.build_ret_void b))
      else ignore (Llvm.build_ret (Llvm.build_load (lltype env ret) p "" b) b));
  (* A miss: the body runs, counting the work of the remembered calls it
     makes, and its result is kept over whatever the entry held. *)
  Llvm.position_at_end miss b;
  ignore (Llvm.build_store (Llvm.build_add st (Llvm.const_int i64 m.Cgt.Memo.charge) "" b) state b);
  let before = Llvm.build_load i64 calls "" b in
  ignore (Llvm.build_store (Llvm.build_add before (Llvm.const_int i64 m.Cgt.Memo.cheapest) "" b) calls b);
  let site = calling fn body bty in
  let work = Llvm.build_sub (Llvm.build_load i64 calls "" b) before "" b in
  let most = Llvm.const_of_int64 i64 (Int64.shift_left 1L 40) false in
  let work = Llvm.build_select (Llvm.build_icmp Llvm.Icmp.Ult work most "" b) work most "" b in
  ignore (Llvm.build_store work (at weight) b);
  let out =
    match ret_passing with
    | Words 1 -> [ Llvm.build_freeze site "" b ]
    | Words n -> List.init n (fun i -> Llvm.build_freeze (Llvm.build_extractvalue site i "" b) "" b)
    | Itself -> of_value ret site
    | Address -> of_place ret (Llvm.param fn 0)
  in
  ignore (Llvm.build_store tag (at 0) b);
  List.iteri (fun i w -> ignore (Llvm.build_store w (at (i + 1)) b)) keys;
  List.iteri (fun i w -> ignore (Llvm.build_store w (at (1 + List.length keys + i)) b)) out;
  finish site
