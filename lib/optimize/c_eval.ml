(* C run at compile time, by interpreting the LLVM IR of the package's C
   module before LLVM has optimized it, with the target's data layout
   (docs/design/ffi.md F16). It is a second evaluator beside [Eval], for a
   second language: memory is bytes ([C_memory]), instructions mean what
   LLVM says ([C_ops]), and a call to a function the module only declares
   runs when it is one of the C library's exact ones ([C_library]) or
   another evaluator's: a function value's adapter, which [Eval] runs.

   Undefined behavior stops the run, and so do a `volatile` or atomic
   access, a fast-math flag, and anything whose result would depend on
   where an allocation lies: C code with undefined behavior has no meaning
   to fold, and leaving it to run is never wrong. *)

open Value
open C_memory

(* What a run spends and what it hands back to the Zane side: [spend]
   charges the fold's budget (F19), and [declared] runs a function the
   module only declares that the other evaluator owns, when it is one. *)
type hooks = { spend : int -> unit; declared : string -> value list -> value option }

(* One fold's C: the module, each global's address once it is made, and
   the depth of calls. Every fold starts from C's state as a run of the
   program starts its Zane code ([create]). *)
type t = {
  ir : C_ir.t;
  hooks : hooks;
  globals : (string, value) Hashtbl.t;
  functions : (string, alloc) Hashtbl.t;
  mutable depth : int;
}

let max_depth = 2_000

let spend t n = t.hooks.spend n

(* A weak declaration's address is null where nothing defines it, which
   the program's link decides. *)
let weak name = stop ("the address of `" ^ name ^ "`, a weak declaration")

let function_address t name =
  (match C_ir.fn t.ir name with Some C_ir.Weak -> weak name | _ -> ());
  let a =
    match Hashtbl.find_opt t.functions name with
    | Some a -> a
    | None ->
        let a = alloc (Function name) ~size:0 ~align:1 in
        Hashtbl.replace t.functions name a;
        a
  in
  Ptr { alloc = a; off = 0 }

let rec zero_of (ty : C_ir.ty) =
  match ty with
  | C_ir.Int bits -> Int (bits, 0L)
  | C_ir.Float -> Fl { double = false; bits = 0L; known = true }
  | C_ir.Double -> Fl { double = true; bits = 0L; known = true }
  | C_ir.Ptr -> Null
  | C_ir.Vector (n, e) -> Vec (Array.make n (zero_of e))
  | C_ir.Struct { fields; _ } -> Agg (Array.map (fun (_, f) -> zero_of f) fields)
  | C_ir.Array { count; elem; _ } -> Agg (Array.init count (fun _ -> zero_of elem))
  | C_ir.Void | C_ir.Other -> Poison

let rec undef_of (ty : C_ir.ty) =
  match ty with
  | C_ir.Vector (n, _) -> Vec (Array.make n Poison)
  | C_ir.Struct { fields; _ } -> Agg (Array.map (fun (_, f) -> undef_of f) fields)
  | C_ir.Array { count; elem; _ } -> Agg (Array.init count (fun _ -> undef_of elem))
  | _ -> Poison

(* The type a scalar value is, for the casts and operations a constant
   expression applies to it. *)
let ty_of = function
  | Int (bits, _) | Addr (bits, _) | Sign (bits, _) -> C_ir.Int bits
  | Fl { double = true; _ } -> C_ir.Double
  | Fl _ -> C_ir.Float
  | _ -> C_ir.Ptr

let rec const t (c : C_ir.const) =
  match c with
  | C_ir.Cint (bits, x) -> int bits x
  | C_ir.Cfloat (double, bits) -> Fl { double; bits; known = true }
  | C_ir.Cnull -> Null
  | C_ir.Cundef ty -> undef_of ty
  | C_ir.Czero ty -> zero_of ty
  | C_ir.Cagg (C_ir.Vector _, cs) -> Vec (Array.map (const t) cs)
  | C_ir.Cagg (_, cs) -> Agg (Array.map (const t) cs)
  | C_ir.Cfunction name -> function_address t name
  | C_ir.Cglobal name -> global t name
  | C_ir.Cgep (base, off) -> (
      let off = Int64.to_int off in
      match const t base with
      | Ptr p -> Ptr { p with off = p.off + off }
      | Null -> if off = 0 then Null else Wild (Int64.of_int off)
      | Wild x -> Wild (Int64.add x (Int64.of_int off))
      | _ -> stop "a constant address into nothing")
  | C_ir.Ccast (op, into, c) ->
      let v = const t c in
      C_ops.cast op 0 (ty_of v) into v
  | C_ir.Cbinary (op, a, b) -> C_ops.binary_int op 0 (const t a) (const t b)
  | C_ir.Cother -> stop "a constant the evaluator does not model"

(* A global's address: a variable the module defines is an allocation made
   from its initializer the first time it is named, a constant one
   read-only; a function's is its own; one defined elsewhere has an
   address and nothing to read. *)
and global t name =
  match Hashtbl.find_opt t.globals name with
  | Some v -> v
  | None -> (
      match C_ir.global_of t.ir name with
      | Some (C_ir.Variable g) ->
          if g.thread_local then stop "a thread-local variable, which each thread has its own of";
          let a = alloc ~readonly:g.constant (Global { name; unnamed = g.unnamed }) ~size:g.size ~align:g.align in
          let v = Ptr { alloc = a; off = 0 } in
          Hashtbl.replace t.globals name v;
          spend t (g.size / 64);
          zero_fill a 0 g.size;
          initialize t a 0 g.ty g.init;
          v
      | Some (C_ir.Alias c) ->
          let v = const t c in
          Hashtbl.replace t.globals name v;
          v
      | Some C_ir.Weak_global -> weak name
      | Some C_ir.Elsewhere | None -> (
          match C_ir.fn t.ir name with
          | Some _ -> function_address t name
          | None ->
              let v = Ptr { alloc = alloc (Extern name) ~size:0 ~align:1; off = 0 } in
              Hashtbl.replace t.globals name v;
              v))

and initialize t a off (ty : C_ir.ty) (c : C_ir.const) =
  match (c, ty) with
  | C_ir.Cundef _, _ | C_ir.Czero _, _ -> ()
  | C_ir.Cagg (_, cs), C_ir.Struct { fields; _ } -> Array.iteri (fun i (o, f) -> initialize t a (off + o) f cs.(i)) fields
  | C_ir.Cagg (_, cs), C_ir.Array { stride; elem; _ } -> Array.iteri (fun i c -> initialize t a (off + (i * stride)) elem c) cs
  | _ -> store a off ty (const t c)

(* ---------------------------------------------------------------------- *)
(* Intrinsics                                                             *)
(* ---------------------------------------------------------------------- *)

let int_args = function [ Int (bits, x); Int (_, y) ] -> (bits, x, y) | _ -> stop "an intrinsic of integers given others"

let rec width v n = if v = 0L then n else width (Int64.shift_right_logical v 1) (n + 1)

let count_bits name bits x zero_poison =
  match name with
  | "ctpop" ->
      let rec pop v n = if v = 0L then n else pop (Int64.logand v (Int64.pred v)) (n + 1) in
      int bits (Int64.of_int (pop x 0))
  | _ when x = 0L -> if zero_poison then Poison else int bits (Int64.of_int bits)
  | "ctlz" -> int bits (Int64.of_int (bits - width x 0))
  | _ ->
      let rec tz v n = if Int64.logand v 1L = 1L then n else tz (Int64.shift_right_logical v 1) (n + 1) in
      int bits (Int64.of_int (tz x 0))

let bswap bits x =
  let r = ref 0L in
  for i = 0 to (bits / 8) - 1 do
    r := Int64.logor (Int64.shift_left !r 8) (Int64.logand (Int64.shift_right_logical x (8 * i)) 0xffL)
  done;
  !r

let bitreverse bits x =
  let r = ref 0L in
  for i = 0 to bits - 1 do
    r := Int64.logor (Int64.shift_left !r 1) (Int64.logand (Int64.shift_right_logical x i) 1L)
  done;
  !r

(* An `llvm.*.with.overflow` intrinsic: the wrapped result and whether the
   operation overflowed. *)
let with_overflow op signed bits x y =
  let wrapped = C_ops.int_binary op 0 bits x y in
  let checked = C_ops.int_binary op (if signed then C_ir.nsw else C_ir.nuw) bits x y in
  Agg [| wrapped; truth (checked = Poison) |]

let saturating op signed bits x y =
  match C_ops.int_binary op (if signed then C_ir.nsw else C_ir.nuw) bits x y with
  | Poison ->
      let high = (op = "add" && C_ops.sext bits y >= 0L) || (op = "sub" && C_ops.sext bits y < 0L) in
      if signed then int bits (if high then mask (bits - 1) (-1L) else Int64.shift_left 1L (bits - 1))
      else int bits (if op = "add" then -1L else 0L)
  | v -> v

(* [x] rounded to an integer, halves to even, as the default rounding mode
   rounds. *)
let round_even x =
  let r = Float.round x in
  if Float.abs (x -. Float.trunc x) = 0.5 then 2. *. Float.round (x /. 2.) else r

let float_unary name (f : fl) =
  let x = C_ops.to_float f in
  match name with
  | "fabs" -> if f.known then Fl { f with bits = Int64.logand f.bits (if f.double then Int64.max_int else 0x7fffffffL) } else Fl f
  | "floor" -> C_ops.of_float f.double (Float.floor x)
  | "ceil" -> C_ops.of_float f.double (Float.ceil x)
  | "trunc" -> C_ops.of_float f.double (Float.trunc x)
  | "round" -> C_ops.of_float f.double (Float.round x)
  | "rint" | "nearbyint" | "roundeven" -> C_ops.of_float f.double (round_even x)
  | "sqrt" -> C_ops.of_float f.double (Float.sqrt x)
  | _ -> stop ("an intrinsic the evaluator does not model: llvm." ^ name)

let float_binary name (a : fl) (b : fl) =
  let x = C_ops.to_float a and y = C_ops.to_float b in
  let zeros_differ = x = 0. && y = 0. && Float.sign_bit x <> Float.sign_bit y in
  match name with
  | "copysign" ->
      if not a.known then Fl a
      else if not b.known then stop "a sign copied from an unknown NaN"
      else
        let sign = if b.double then Int64.min_int else 0x80000000L in
        Fl { a with bits = Int64.logor (Int64.logand a.bits (Int64.lognot sign)) (Int64.logand b.bits sign) }
  | ("minnum" | "maxnum") when zeros_differ -> stop "a minnum or maxnum of two zeros, which may give either"
  | "minnum" -> C_ops.of_float a.double (if Float.is_nan x then y else if Float.is_nan y then x else Float.min x y)
  | "maxnum" -> C_ops.of_float a.double (if Float.is_nan x then y else if Float.is_nan y then x else Float.max x y)
  | "minimum" -> C_ops.of_float a.double (Float.min x y)
  | "maximum" -> C_ops.of_float a.double (Float.max x y)
  | _ -> stop ("an intrinsic the evaluator does not model: llvm." ^ name)

(* The intrinsic's family: `llvm.memcpy.p0.p0.i64` is `memcpy`, and
   `llvm.sadd.with.overflow.i32` is `sadd.with.overflow`. *)
let family name =
  let parts = String.split_on_char '.' name in
  let rec base acc = function
    | [] -> List.rev acc
    | p :: rest ->
        let typed =
          String.length p > 0
          && (p.[0] = 'i' || p.[0] = 'f' || p.[0] = 'p' || p.[0] = 'v')
          && String.length p > 1
          && (match p.[1] with '0' .. '9' -> true | _ -> false)
        in
        if typed || p = "f32" || p = "f64" then List.rev acc else base (p :: acc) rest
  in
  String.concat "." (base [] (List.tl parts))

let truthy = function Int (1, 1L) -> true | Int (1, 0L) -> false | Poison -> stop "poison reaching a branch" | _ -> stop "a condition that is not an i1"

let rec intrinsic t frame ret name (args : value list) =
  let fam = family name in
  let each f = match args with [ Vec xs ] -> Vec (Array.map (fun x -> f [ x ]) xs) | _ -> f args in
  match (fam, args) with
  | ("memcpy" | "memcpy.inline"), [ d; s; n; v ] ->
      if truthy v then stop "a volatile memcpy";
      C_library.memcpy (spend t) d s n
  | "memmove", [ d; s; n; v ] ->
      if truthy v then stop "a volatile memmove";
      C_library.memmove (spend t) d s n
  | ("memset" | "memset.inline"), [ d; c; n; v ] ->
      if truthy v then stop "a volatile memset";
      C_library.memset (spend t) d c n
  | ( ( "lifetime.start" | "lifetime.end" | "dbg.declare" | "dbg.value" | "dbg.label" | "dbg.assign"
      | "experimental.noalias.scope.decl" | "prefetch" | "donothing" | "var.annotation" | "sideeffect" ),
      _ ) ->
      Poison
  | "assume", [ c ] -> if (match c with Int (1, 1L) -> false | _ -> true) then stop "an assumption that does not hold" else Poison
  | ("expect" | "expect.with.probability" | "ssa.copy" | "ptr.annotation" | "launder.invariant.group" | "strip.invariant.group"), v :: _ -> v
  | ("smin" | "smax" | "umin" | "umax"), [ Vec xs; Vec ys ] ->
      Vec (Array.map2 (fun x y -> intrinsic t frame ret name [ x; y ]) xs ys)
  | ("smin" | "smax" | "umin" | "umax"), _ ->
      let bits, x, y = int_args args in
      let c = if fam.[0] = 's' then compare (C_ops.sext bits x) (C_ops.sext bits y) else Int64.unsigned_compare x y in
      int bits (if (c <= 0) = (fam = "smin" || fam = "umin") then x else y)
  | "abs", [ Int (bits, x); flag ] ->
      let v = C_ops.sext bits x in
      if v = C_ops.sext bits (Int64.shift_left 1L (bits - 1)) then if truthy flag then Poison else Int (bits, x)
      else int bits (Int64.abs v)
  | ("ctpop" | "ctlz" | "cttz"), Int (bits, x) :: rest ->
      count_bits fam bits x (match rest with [ f ] -> truthy f | _ -> false)
  | "bswap", [ Int (bits, x) ] -> Int (bits, bswap bits x)
  | "bitreverse", [ Int (bits, x) ] -> Int (bits, bitreverse bits x)
  | ("fshl" | "fshr"), [ Int (bits, a); Int (_, b); Int (_, s) ] ->
      let s = Int64.to_int (Int64.unsigned_rem s (Int64.of_int bits)) in
      if s = 0 then Int (bits, if fam = "fshl" then a else b)
      else if fam = "fshl" then int bits (Int64.logor (Int64.shift_left a s) (Int64.shift_right_logical b (bits - s)))
      else int bits (Int64.logor (Int64.shift_left a (bits - s)) (Int64.shift_right_logical b s))
  | ( ("sadd.with.overflow" | "uadd.with.overflow" | "ssub.with.overflow" | "usub.with.overflow" | "smul.with.overflow"
      | "umul.with.overflow"),
      _ ) ->
      let bits, x, y = int_args args in
      with_overflow (String.sub fam 1 3) (fam.[0] = 's') bits x y
  | ("sadd.sat" | "uadd.sat" | "ssub.sat" | "usub.sat"), _ ->
      let bits, x, y = int_args args in
      saturating (String.sub fam 1 3) (fam.[0] = 's') bits x y
  | _, (Poison :: _) -> Poison
  | ("fabs" | "floor" | "ceil" | "trunc" | "round" | "rint" | "nearbyint" | "roundeven" | "sqrt"), _ ->
      each (function [ Fl f ] -> float_unary fam f | _ -> stop "a float intrinsic given something not a float")
  | ("copysign" | "minnum" | "maxnum" | "minimum" | "maximum"), [ Vec xs; Vec ys ] ->
      Vec (Array.map2 (fun x y -> intrinsic t frame ret name [ x; y ]) xs ys)
  | ("copysign" | "minnum" | "maxnum" | "minimum" | "maximum"), [ Fl a; Fl b ] -> float_binary fam a b
  | "fma", [ Fl a; Fl b; Fl c ] when a.double ->
      C_ops.of_float true (Float.fma (C_ops.to_float a) (C_ops.to_float b) (C_ops.to_float c))
  | ("lrint" | "llrint" | "lround" | "llround"), [ Fl f ] ->
      let x = C_ops.to_float f in
      let r = if fam = "lrint" || fam = "llrint" then round_even x else Float.round x in
      let bits = match ret with C_ir.Int b -> b | _ -> 64 in
      C_ops.float_to_int ~unsigned:false bits { double = true; bits = Int64.bits_of_float r; known = not (Float.is_nan r) }
  | "stacksave", [] -> Wild (Int64.of_int (List.length !frame + 1))
  | "stackrestore", [ Wild n ] ->
      let keep = Int64.to_int n - 1 in
      let rec drop n l = if n <= keep then l else match l with a :: rest -> a.freed <- true; drop (n - 1) rest | [] -> [] in
      frame := drop (List.length !frame) !frame;
      Poison
  | "threadlocal.address", _ -> stop "a thread-local variable, which each thread has its own of"
  | _ -> stop ("an intrinsic the evaluator does not model: " ^ name)

(* ---------------------------------------------------------------------- *)
(* Instructions                                                           *)
(* ---------------------------------------------------------------------- *)

type next = Jump of int | Return of value

let ptr_of = function
  | Ptr p -> p
  | Null -> stop "an access through a null pointer"
  | Poison -> stop "an access through poison"
  | _ -> stop "an access through an address that names nothing"

let rec path_get v = function
  | [] -> v
  | i :: rest -> ( match v with Agg a | Vec a -> path_get a.(i) rest | _ -> stop "an index into no aggregate")

let rec path_set v path x =
  match (path, v) with
  | [], _ -> x
  | i :: rest, Agg a ->
      let a = Array.copy a in
      a.(i) <- path_set a.(i) rest x;
      Agg a
  | _ -> stop "an index into no aggregate"

let rec has_poison = function Poison -> true | Vec a | Agg a -> Array.exists has_poison a | _ -> false

let is_float_op = function "fadd" | "fsub" | "fmul" | "fdiv" | "frem" -> true | _ -> false

(* Whether [ty] holds an integer wider than the evaluator's 64 bits. Every
   value is a constant, which has none, or an instruction's, so refusing
   each such instruction keeps them all out. *)
let rec wide (ty : C_ir.ty) =
  match ty with
  | C_ir.Int n -> n > 64
  | C_ir.Vector (_, e) -> wide e
  | C_ir.Struct { fields; _ } -> Array.exists (fun (_, f) -> wide f) fields
  | C_ir.Array { elem; _ } -> wide elem
  | _ -> false

(* A `select` of [a] or [b] by [c], elementwise for vectors. *)
let select c a b =
  match (c, a, b) with
  | Int (1, c), _, _ -> if c = 1L then a else b
  | Vec cs, Vec xs, Vec ys -> Vec (Array.mapi (fun k c -> match c with Int (1, 1L) -> xs.(k) | Int _ -> ys.(k) | _ -> Poison) cs)
  | Vec _, _, _ -> stop "a select of vectors given others"
  | Poison, _, _ -> Poison
  | _ -> stop "a select on something not an i1"

let rec call t name (args : value list) =
  if String.starts_with ~prefix:"llvm." name then stop ("an intrinsic called by its address: " ^ name);
  match C_ir.fn t.ir name with
  | Some (C_ir.Body f) -> run t f args
  | Some C_ir.Weak -> weak name
  | Some (C_ir.Declared _) | None -> (
      match t.hooks.declared name args with
      | Some v -> v
      | None -> (
          match C_library.call ~spend:(spend t) name args with
          | Some v -> v
          | None -> stop ("a call to `" ^ name ^ "`, which has no body here")))

and call_value t f args =
  match f with
  | Ptr { alloc = { kind = Function name; _ }; off = 0 } -> call t name args
  | _ -> stop "a call through an address that is no function"

and run t (f : C_ir.func) args =
  if f.C_ir.variadic then stop "a call of a variadic C function";
  t.depth <- t.depth + 1;
  if t.depth > max_depth then stop "calls nested too deep";
  let count = Array.fold_left (fun n b -> n + Array.length b) f.C_ir.params f.C_ir.blocks in
  let regs = Array.make count Poison in
  List.iteri (fun i v -> if i < f.C_ir.params then regs.(i) <- v) args;
  let frame = ref [] in
  let finish () =
    List.iter (fun a -> a.freed <- true) !frame;
    t.depth <- t.depth - 1
  in
  let rec go prev b =
    match block t frame regs f prev b with Jump next -> go b next | Return v -> v
  in
  match go (-1) 0 with
  | v ->
      finish ();
      v
  | exception e ->
      finish ();
      raise e

and operand t regs = function
  | C_ir.Reg r -> regs.(r)
  | C_ir.Const c -> const t c
  | C_ir.Asm -> stop "inline assembly"
  | C_ir.Metadata -> Poison

and block t frame regs f prev b =
  let instrs = f.C_ir.blocks.(b) in
  let value = operand t regs in
  (* A block's phis take their values together, from the block before. *)
  let phis = ref [] in
  Array.iter
    (fun (i : C_ir.instr) ->
      match i.C_ir.op with
      | C_ir.Phi incoming -> (
          match List.assoc_opt prev incoming with
          | Some o -> phis := (i.C_ir.reg, value o) :: !phis
          | None -> stop "a phi with no value for the block before")
      | _ -> ())
    instrs;
  List.iter (fun (r, v) -> regs.(r) <- v) !phis;
  let rec step k =
    let i = instrs.(k) in
    spend t 1;
    if wide i.C_ir.ty then stop "an integer wider than 64 bits";
    match exec t frame regs i with Some next -> next | None -> step (k + 1)
  in
  step 0

and exec t frame regs (i : C_ir.instr) =
  let value = operand t regs in
  let set v =
    regs.(i.C_ir.reg) <- v;
    None
  in
  let fast () = if C_ir.has C_ir.fast i then stop "a float operation with a fast-math flag" in
  match i.C_ir.op with
  | C_ir.Phi _ -> None
  | C_ir.Plain { pred; args } -> (
      let arg k = value args.(k) in
      match i.C_ir.opcode with
      | "fneg" ->
          fast ();
          set (C_ops.fneg (arg 0))
      | "icmp" -> set (C_ops.icmp pred (arg 0) (arg 1))
      | "fcmp" ->
          fast ();
          set (C_ops.fcmp pred (arg 0) (arg 1))
      | "select" -> set (select (arg 0) (arg 1) (arg 2))
      | "freeze" ->
          let v = arg 0 in
          if has_poison v then stop "a freeze of poison, which takes an arbitrary value";
          set v
      | "extractelement" -> (
          match (arg 0, arg 1) with
          | Vec xs, Int (_, k) when Int64.to_int k < Array.length xs -> set xs.(Int64.to_int k)
          | _ -> set Poison)
      | "insertelement" -> (
          match (arg 0, arg 2) with
          | Vec xs, Int (_, k) when Int64.to_int k < Array.length xs ->
              let xs = Array.copy xs in
              xs.(Int64.to_int k) <- arg 1;
              set (Vec xs)
          | _ -> set Poison)
      | op when is_float_op op ->
          fast ();
          set (C_ops.binary_float op (arg 0) (arg 1))
      | op -> set (C_ops.binary_int op i.C_ir.flags (arg 0) (arg 1)))
  | C_ir.Cast { from; arg } ->
      fast ();
      set (C_ops.cast i.C_ir.opcode i.C_ir.flags from i.C_ir.ty (value arg))
  | C_ir.Alloca { size; align; count } -> (
      match value count with
      | Int (_, n) ->
          let n = C_library.small (Int64.mul (Int64.of_int size) n) in
          spend t (n / 64);
          let a = alloc Stack ~size:n ~align in
          frame := a :: !frame;
          set (Ptr { alloc = a; off = 0 })
      | _ -> stop "an alloca of an unknown count")
  | C_ir.Load { volatile = true; _ } | C_ir.Store { volatile = true; _ } ->
      stop "a volatile access, which the program makes at run time"
  | C_ir.Load { atomic = true; _ } | C_ir.Store { atomic = true; _ } ->
      stop "an atomic access, which another thread may see"
  | C_ir.Load { align; ptr; _ } ->
      let p = ptr_of (value ptr) in
      check p (store_size i.C_ir.ty) align;
      set (load p.alloc p.off i.C_ir.ty)
  | C_ir.Store { align; ty; value = v; ptr; _ } ->
      let v = value v in
      let p = ptr_of (value ptr) in
      check ~write:true p (store_size ty) align;
      store p.alloc p.off ty v;
      None
  | C_ir.Gep { base; offset; terms } -> (
      let index (o, bits, scale) =
        match value o with
        | Int (_, x) ->
            (* A product that wraps would move the address by less than
               it asks, so it stops, as a move no allocation spans does. *)
            let x = C_ops.sext bits x in
            let p = Int64.mul x scale in
            if scale <> 0L && Int64.div p scale <> x then stop "an address moved further than any allocation spans";
            Some p
        | Poison -> None
        | Addr _ -> stop C_ops.number
        | _ -> stop "an index that is not an integer"
      in
      let parts = List.map index terms in
      if List.mem None parts then set Poison
      else
        let total = List.fold_left (fun s x -> Int64.add s (Option.get x)) offset parts in
        match value base with
        | Ptr p -> set (Ptr (moved p total))
        | Null -> set (if total = 0L then Null else Wild total)
        | Wild x -> set (Wild (Int64.add x total))
        | Poison -> set Poison
        | _ -> stop "an address computed from something not an address")
  | C_ir.Call { callee; args } ->
      (* A `byval` argument's copy lives as long as the call: it is paid
         for as `mem*`-style work and freed when the call returns. *)
      let copies = ref [] in
      let pass (byval, o) =
        let v = value o in
        if v = Poison then stop "poison passed to a call";
        if byval < 0 then v
        else
          let src = ptr_of v in
          spend t (byval / 64);
          let a = alloc Stack ~size:byval ~align:16 in
          copies := a :: !copies;
          copy ~dst:{ alloc = a; off = 0 } ~src byval;
          Ptr { alloc = a; off = 0 }
      in
      let args = List.map pass args in
      let result =
        match callee with
        | C_ir.Direct name when String.starts_with ~prefix:"llvm." name -> intrinsic t frame i.C_ir.ty name args
        | C_ir.Direct name -> call t name args
        | C_ir.Indirect o -> call_value t (value o) args
        | C_ir.Inline_asm -> stop "inline assembly"
      in
      List.iter (fun a -> a.freed <- true) !copies;
      set result
  | C_ir.Extract { indices; agg } -> set (path_get (value agg) indices)
  | C_ir.Insert { indices; agg; value = v } -> set (path_set (value agg) indices (value v))
  | C_ir.Shuffle { a; b; mask } -> (
      match (value a, value b) with
      | Vec xs, Vec ys ->
          let n = Array.length xs in
          set (Vec (Array.map (fun m -> if m < 0 then Poison else if m < n then xs.(m) else ys.(m - n)) mask))
      | _ -> stop "a shuffle of something not a vector")
  | C_ir.Ret v -> Some (Return (match v with Some o -> value o | None -> Poison))
  | C_ir.Br b -> Some (Jump b)
  | C_ir.Cond_br { cond; yes; no } -> Some (Jump (if truthy (value cond) then yes else no))
  | C_ir.Switch { value = v; default; cases } -> (
      match value v with
      | Int (bits, x) -> Some (Jump (match List.find_opt (fun (c, _) -> mask bits c = x) cases with Some (_, b) -> b | None -> default))
      | Poison -> stop "poison reaching a branch"
      | Addr _ -> stop C_ops.number
      | _ -> stop "a switch on something not an integer")
  | C_ir.Unreachable -> stop "unreachable code reached, which is undefined behavior"
  | C_ir.Unknown -> stop ("an instruction the evaluator does not model: " ^ i.C_ir.opcode)

(* ---------------------------------------------------------------------- *)
(* A fold's C                                                             *)
(* ---------------------------------------------------------------------- *)

(* The module's constructors, by priority, as `llvm.global_ctors` lists
   them: each entry its priority, function and data. *)
let constructors t =
  match C_ir.global_of t.ir "llvm.global_ctors" with
  | Some (C_ir.Variable { init = C_ir.Cagg (_, entries); _ }) ->
      let entry = function
        | C_ir.Cagg (_, [| C_ir.Cint (_, priority); C_ir.Cfunction f; _ |]) -> Some (priority, f)
        | _ -> None
      in
      List.map snd (List.stable_sort (fun (a, _) (b, _) -> compare a b) (List.filter_map entry (Array.to_list entries)))
  | _ -> []

(* A fold's C, its memory as a run of the program finds it when its Zane
   code starts: every global from its initializer, and then each
   constructor run, as the program runs them before `main`. *)
let create ir hooks =
  if not ir.C_ir.little then stop "C for a big-endian target";
  let t = { ir; hooks; globals = Hashtbl.create 16; functions = Hashtbl.create 16; depth = 0 } in
  List.iter (fun f -> ignore (call t f [])) (constructors t);
  t
