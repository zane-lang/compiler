(* The CGT run at compile time (docs/design/optimization.md O5). Each node
   means here what codegen makes it mean in lib/codegen/emit.ml, and each
   runtime function what runtime/ does, except where the bytes of a value
   live: arenas, regions and the blocks that move between them are nothing
   here, since no program can tell one placement from another
   (docs/design/lowering.md §9).

   A run stops, with [Value.Stop], at anything it cannot know: an input, a
   local the fold has no value for, a function with no body here, a division
   by zero or an index out of range (which must stop the program when it
   runs), or a budget spent. *)

open Cgt.Nodes
open Value

(* What a run did that the running program must still do, in order (O4). *)
type output = Print of string | Set_threads of int64 | Set_threads_auto

(* A package constant's two variables (docs/design/lowering.md L16), and its
   value once it is known to fold. *)
type constant = { maker : string; state : string; value : string; mutable known : const option }

(* A remembered call: its result, its outputs in order, and how many
   outputs there are and how many bytes their text holds, counted once when
   it is recorded so that a replay can be charged without walking them. *)
type memo = { result : const; outputs : output list; count : int; text : int }

(* A function the evaluator can call, and whether its calls are remembered
   (O6): when its body makes more than one call, or a loop, a spawn, a call
   through a value, recursion, or work that grows with a value's size (a
   runtime function, a copy or an overwrite) is reachable from it. Any other
   call runs one chain of calls, each a bounded number of steps, fewer than a
   remembered call takes to keep and look up. Known the first time it is
   asked. *)
type entry = { func : Func.t; mutable remembers : remembers; mutable frame : int }
and remembers = Unknown | Asking | Known of bool

module Funcs = Hashtbl.Make (struct
  type t = string

  let equal = String.equal
  let hash = Hashtbl.hash
end)

let entry (f : Func.t) = { func = f; remembers = Unknown; frame = 4 }

let functions fs =
  let t = Funcs.create 64 in
  List.iter (fun (f : Func.t) -> Funcs.replace t f.Func.symbol (entry f)) fs;
  t

(* A function being asked about again is recursive, which is worth
   remembering. *)
let rec remembers funcs e =
  match e.remembers with
  | Known r -> r
  | Asking -> true
  | Unknown ->
      e.remembers <- Asking;
      (* Two calls in one body can double the work at each level of calls
         below it, which only remembering keeps linear in their depth. *)
      let calls = ref 0 in
      let r =
        Cgt.Traverse.exists_in e.func.Func.body
          ~expr:(fun x ->
            match x.Expr.node with
            | Expr.Call { fn; _ } ->
                incr calls;
                !calls > 1 || Option.fold ~none:false ~some:(remembers funcs) (Funcs.find_opt funcs fn)
            | Expr.Call_value _ | Expr.Runtime _ | Expr.Copy _ -> true
            | _ -> false)
          ~stat:(function Stat.Repeat _ | Stat.Spawn _ | Stat.Overwrite _ -> true | _ -> false)
      in
      e.remembers <- Known r;
      r

type program = {
  funcs : entry Funcs.t;
  layouts : (Layout.t, Layout.position list) Hashtbl.t;
  globals : (string, Global.t) Hashtbl.t;
  (* By the symbol of each of the constant's variables. *)
  constants : (string, constant) Hashtbl.t;
  (* A call's result and what it output, by the function and its
     arguments (O6). *)
  memo : memo Key.t;
  (* The steps every fold of the program may take together, so that many
     calls that each run out of budget cannot make a build slow. *)
  mutable left : int;
}

(* The steps one fold may take, all the folds of a program, and how deep
   calls may go (O6). *)
let budget = 5_000_000
let total = 50_000_000
let max_depth = 2_000

type run = {
  prog : program;
  mutable steps : int;
  mutable depth : int;
  mutable outputs : output list;
  (* How many outputs [outputs] holds, and the bytes of their text. *)
  mutable output_count : int;
  mutable output_bytes : int;
  cells : (string, cell) Hashtbl.t;
  (* What each variable held when the run first read it, and that as a
     constant: a store into a member writes the value in place. *)
  initial : (string, v * const option) Hashtbl.t;
  (* The constant this run is making, when it is making one (Constants). *)
  making : string option;
}

(* The locals of one call. The function being folded has [outer]: the value
   the fold knows a local of it holds, read the first time it is needed. *)
module Locals = struct
  (* The cell each local number names: numbers below [dense] in an array
     grown as they are bound, and any above in a table. A frame then costs
     at most [dense] slots however many locals its function numbers, which
     keeps a fold of a large function from growing with the square of its
     locals. *)
  type t = { mutable cells : cell option array; mutable far : (int, cell) Hashtbl.t option }

  let dense = 1024
  let create ?(size = 8) () = { cells = Array.make (min size dense) None; far = None }
  let size t = Array.length t.cells

  let find_opt t id =
    if id >= 0 && id < Array.length t.cells then t.cells.(id)
    else Option.bind t.far (fun h -> Hashtbl.find_opt h id)

  let replace t id c =
    if id < 0 then stop "a local with no number";
    let n = Array.length t.cells in
    if id < n then t.cells.(id) <- Some c
    else if id < dense then begin
      let cells = Array.make (min dense (max (2 * n) (id + 1))) None in
      Array.blit t.cells 0 cells 0 n;
      t.cells <- cells;
      cells.(id) <- Some c
    end
    else
      match t.far with
      | Some h -> Hashtbl.replace h id c
      | None ->
          let h = Hashtbl.create 8 in
          Hashtbl.replace h id c;
          t.far <- Some h

  let iter f t =
    Array.iteri (fun id c -> Option.iter (f id) c) t.cells;
    Option.iter (Hashtbl.iter f) t.far
end

type frame = { locals : Locals.t; outer : (int -> (const * Ty.t) option) option }

exception Left of int
exception Returned of v

let start ?making prog =
  {
    prog;
    steps = budget;
    depth = 0;
    outputs = [];
    output_count = 0;
    output_bytes = 0;
    cells = Hashtbl.create 8;
    initial = Hashtbl.create 8;
    making;
  }

(* Whether the run wrote a variable of the program, which folding the code
   that did it would lose: only a run that makes a constant may. *)
let wrote_globals run =
  Hashtbl.fold
    (fun g (c : cell) w ->
      w
      ||
      let v, held = Hashtbl.find run.initial g in
      c.value != v
      ||
      match (export c.value, held) with
      | Some now, Some held -> not (same now held)
      | None, None -> false
      | _ -> true)
    run.cells false

let spend run n =
  run.steps <- run.steps - n;
  run.prog.left <- run.prog.left - n;
  if run.steps <= 0 || run.prog.left <= 0 then stop "the step budget ran out"

let tick run = spend run 1

(* Work that grows with the size of what it makes or copies costs a step for
   each 64 bytes, charged before the work is done, so a few steps cannot
   build a value of any size. *)
let bytes run n = if n >= 64 then spend run (n / 64)

(* Outputs made or replayed, charged by their size. Each output weighs its
   text's length and one more, so that many outputs with no text are not
   free, and a run whose outputs weigh more than a folded result may
   materialize to stops (O6). A call's outputs are part of its run's, so a
   call whose outputs pass the cap stops before it can be remembered. *)
let charge_outputs run ~count ~text =
  bytes run (text + count);
  run.output_count <- run.output_count + count;
  run.output_bytes <- run.output_bytes + text;
  if run.output_bytes + run.output_count > max_size then stop "output too large to fold"

let output run o =
  let text = match o with Print s -> String.length s | Set_threads _ | Set_threads_auto -> 0 in
  charge_outputs run ~count:1 ~text;
  run.outputs <- o :: run.outputs
let sized run (t : Ty.t) =
  match t with
  (* Scalars are smaller than a step's worth of bytes. *)
  | Ty.Void | Ty.I1 | Ty.I32 | Ty.I64 | Ty.F32 | Ty.F64 | Ty.Handle | Ty.Ptr -> ()
  | Ty.Struct _ | Ty.Array _ | Ty.Sum _ -> bytes run (fst (Ty.size_align t))

(* ---------------------------------------------------------------------- *)
(* Places                                                                 *)
(* ---------------------------------------------------------------------- *)

let local fr id =
  match Locals.find_opt fr.locals id with
  | Some c -> c
  | None -> (
      match Option.bind fr.outer (fun known -> known id) with
      | Some (c, ty) ->
          let c = cell ~origin:(Outer id) ty (import c) in
          Locals.replace fr.locals id c;
          c
      | None -> stop "a local whose value is not known")

let bind fr id ty v = Locals.replace fr.locals id (cell ty v)

(* A variable of the program: a constant's value and state, or a program
   value such as the console, which holds nothing a program reads. *)
let global run g =
  match Hashtbl.find_opt run.cells g with
  | Some c -> c
  | None ->
      let ty = match Hashtbl.find_opt run.prog.globals g with Some g -> g.Global.ty | None -> Ty.I64 in
      (* A constant that does not fold has no value here: its state stops a
         read of it, and its value holds nothing until the run that makes
         it stores one. *)
      let value =
        match Hashtbl.find_opt run.prog.constants g with
        | Some k when g = k.state -> (
            match (k.known, run.making) with
            | Some _, _ -> VInt (-1L)
            | None, Some m when m = k.state -> VInt 0L
            | None, _ -> VNull)
        | Some { known = Some c; _ } -> import c
        | Some { known = None; _ } -> VNull
        | None -> zero ty
      in
      let c = cell ~origin:(Global g) ty value in
      Hashtbl.replace run.cells g c;
      Hashtbl.replace run.initial g (value, export value);
      c

let ptr_of = function VPtr p -> p | _ -> stop "an address that names nothing"

let int_of = function
  | VInt i -> i
  | _ -> stop "an integer that is not one"

let bool_of = function VBool b -> b | _ -> stop "a condition that is not a Bool"
let text_of = function VText s -> s | _ -> stop "a string that is not one"

(* An address down [path] from [p], through a value of type [within]: a
   sum's case whose payload is nothing takes no step (emit.ml). *)
let offset (p : ptr) within path =
  let steps, _ =
    List.fold_left
      (fun (steps, t) i ->
        match t with
        | Ty.Struct ts -> (Member i :: steps, List.nth ts i)
        | Ty.Sum ts when List.nth ts i = Ty.Void -> (steps, Ty.Void)
        | Ty.Sum ts -> (Payload i :: steps, List.nth ts i)
        | _ -> stop "an offset through something not a struct")
      ([], within) path
  in
  { p with path = p.path @ List.rev steps }

(* ---------------------------------------------------------------------- *)
(* Arithmetic, as emit.ml's [binary] and [divide]                         *)
(* ---------------------------------------------------------------------- *)

(* A NaN's sign and payload are the host's, and no program can tell one NaN
   from another, so every NaN folds to the same one: the same source folds
   the same way on any machine (O6). *)
let canonical f = if Float.is_nan f then Int64.float_of_bits 0x7FF8_0000_0000_0000L else f

(* A float as its type holds it: an [F32]'s result is rounded to a single,
   which is the one rounding the machine's own single operation makes. *)
let float (t : Ty.t) f = canonical (match t with Ty.F32 -> Scalar.single f | _ -> f)

(* Canonical scientific notation, as runtime/block.c's [zane_decimal_text]. *)
let decimal_text text =
  match String.index_opt text 'e' with
  | None -> text
  | Some exponent ->
      let power =
        int_of_string (String.sub text (exponent + 1) (String.length text - exponent - 1))
      in
      let rec trim at = if text.[at - 1] = '0' then trim (at - 1) else at in
      let last =
        if String.contains text '.' then
          let at = trim exponent in
          if text.[at - 1] = '.' then at - 1 else at
        else exponent
      in
      Printf.sprintf "%se%d" (String.sub text 0 last) power

(* Compare all round-tripping candidates, including scientific notation
   where %g prefers a longer fixed spelling. Ties retain the first (least
   precise) candidate. The runtime makes the same search in the C locale. *)
let float_text (t : Ty.t) f =
  if Float.is_nan f then "nan"
  else if f = Float.infinity then "inf"
  else if f = Float.neg_infinity then "-inf"
  else
    let same a b =
      match t with
      | Ty.F32 -> Int32.bits_of_float (Scalar.single a) = Int32.bits_of_float (Scalar.single b)
      | _ -> Int64.bits_of_float a = Int64.bits_of_float b
    in
    let limit = if t = Ty.F32 then 9 else 17 in
    let best = ref None in
    for precision = 1 to limit do
      List.iter
        (fun text ->
          let text = decimal_text text in
          if same f (float_of_string text) then
            match !best with
            | Some held when String.length held <= String.length text -> ()
            | _ -> best := Some text)
        [ Printf.sprintf "%.*g" precision f; Printf.sprintf "%.*e" (precision - 1) f ]
    done;
    match !best with Some text -> text | None -> stop "formatting a float"

(* A number read from text as the runtime reads it (types.md §2.10): a
   literal's digits, with an optional `-` first and, for a float, an
   optional `.` with digits on both sides. The text is checked here, so
   [Int64.of_string] and [float_of_string] see only that form, and read it
   as the runtime's `strtoll` and `strtod` do. *)
let numeric_text ~fraction text =
  let n = String.length text in
  let digits from =
    let rec go i = if i < n && text.[i] >= '0' && text.[i] <= '9' then go (i + 1) else i in
    go from
  in
  let start = if n > 0 && text.[0] = '-' then 1 else 0 in
  let whole = digits start in
  if whole = start then false
  else if whole = n then true
  else if fraction && text.[whole] = '.' then
    let frac = digits (whole + 1) in
    frac > whole + 1 && frac = n
  else false

let parse_i64 text =
  if numeric_text ~fraction:false text then Int64.of_string_opt text else None

let parse_f64 text =
  if numeric_text ~fraction:true text then
    let f = float_of_string text in
    if Float.is_finite f then Some f else None
  else None

let binary (op : Expr.binop) (t : Ty.t) l r =
  match (t, op, l, r) with
  | (Ty.I64 | Ty.I32), Expr.Add, VInt a, VInt b -> VInt (int t (Int64.add a b))
  | (Ty.I64 | Ty.I32), Expr.Mul, VInt a, VInt b -> VInt (int t (Int64.mul a b))
  (* A division by zero gives zero, and the one quotient an integer cannot
     hold wraps, as [+] and [*] do. *)
  | (Ty.I64 | Ty.I32), Expr.Div, VInt _, VInt 0L -> VInt 0L
  | (Ty.I64 | Ty.I32), Expr.Div, VInt a, VInt -1L -> VInt (int t (Int64.neg a))
  | (Ty.I64 | Ty.I32), Expr.Div, VInt a, VInt b -> VInt (int t (Int64.div a b))
  | (Ty.I64 | Ty.I32), Expr.Eq, VInt a, VInt b -> VBool (Int64.equal a b)
  | (Ty.I64 | Ty.I32), Expr.Less, VInt a, VInt b -> VBool (Int64.compare a b < 0)
  | (Ty.F64 | Ty.F32), Expr.Add, VFloat a, VFloat b -> VFloat (float t (a +. b))
  | (Ty.F64 | Ty.F32), Expr.Mul, VFloat a, VFloat b -> VFloat (float t (a *. b))
  | (Ty.F64 | Ty.F32), Expr.Div, VFloat a, VFloat b -> VFloat (float t (a /. b))
  (* Ordered comparisons: a NaN is neither equal to nor less than anything. *)
  | (Ty.F64 | Ty.F32), Expr.Eq, VFloat a, VFloat b -> VBool (a = b)
  | (Ty.F64 | Ty.F32), Expr.Less, VFloat a, VFloat b -> VBool (a < b)
  | Ty.I1, Expr.Add, VBool a, VBool b -> VBool (a || b)
  | Ty.I1, Expr.Mul, VBool a, VBool b -> VBool (a && b)
  | Ty.I1, Expr.Eq, VBool a, VBool b -> VBool (a = b)
  | _ -> stop "an operator on operands it has no meaning for"

let flip (t : Ty.t) v =
  match (t, v) with
  | (Ty.I64 | Ty.I32), VInt a -> VInt (int t (Int64.neg a))
  | (Ty.F64 | Ty.F32), VFloat a -> VFloat (canonical (Float.neg a))
  | Ty.I1, VBool a -> VBool (not a)
  | _ -> stop "`~` on a value it does not flip"

(* A math function of `@math$` (math.md §2), as emit.ml's [math]. An
   integer's bits are its low [width] ones, read unsigned where a shift or
   a count needs them so. *)
let math (fn : Cgt.Math.fn) (t : Ty.t) args =
  let width = Scalar.bits t in
  let unsigned a = if width = 32 then Int64.logand a 0xFFFF_FFFFL else a in
  let count c = Int64.to_int (Int64.logand c (Int64.of_int (width - 1))) in
  let rotate a n =
    let u = unsigned a in
    if n = 0 then a
    else int t (Int64.logor (Int64.shift_left u n) (Int64.shift_right_logical u (width - n)))
  in
  let rec ones a n = if Int64.equal a 0L then n else ones (Int64.logand a (Int64.pred a)) (n + 1) in
  let rec length a n = if Int64.equal a 0L then n else length (Int64.shift_right_logical a 1) (n + 1) in
  (* IEEE 754's minimum and maximum: a NaN wins, and a negative zero is the
     lesser zero. *)
  let least a b =
    if Float.is_nan a || Float.is_nan b then Float.nan
    else if a = b then if Float.sign_bit a then a else b
    else if a < b then a
    else b
  in
  let greatest a b =
    if Float.is_nan a || Float.is_nan b then Float.nan
    else if a = b then if Float.sign_bit a then b else a
    else if a > b then a
    else b
  in
  (* To nearest, a tie to the even neighbour. Past 2^52 a double holds
     only integers. *)
  let round_even x =
    if (not (Float.is_finite x)) || Float.abs x >= 0x1p52 then x
    else
      let r = Float.round x in
      if Float.abs (x -. Float.trunc x) = 0.5 then 2. *. Float.round (x /. 2.) else r
  in
  match (fn, args) with
  | Cgt.Math.Bit_and, [ VInt a; VInt b ] -> VInt (int t (Int64.logand a b))
  | Cgt.Math.Bit_or, [ VInt a; VInt b ] -> VInt (int t (Int64.logor a b))
  | Cgt.Math.Bit_xor, [ VInt a; VInt b ] -> VInt (int t (Int64.logxor a b))
  | Cgt.Math.Bit_not, [ VInt a ] -> VInt (int t (Int64.lognot a))
  | Cgt.Math.Shift_left, [ VInt a; VInt c ] -> VInt (int t (Int64.shift_left a (count c)))
  | Cgt.Math.Shift_right, [ VInt a; VInt c ] -> VInt (int t (Int64.shift_right a (count c)))
  | Cgt.Math.Shift_right_logical, [ VInt a; VInt c ] ->
      VInt (int t (Int64.shift_right_logical (unsigned a) (count c)))
  | Cgt.Math.Rotate_left, [ VInt a; VInt c ] -> VInt (rotate a (count c))
  | Cgt.Math.Rotate_right, [ VInt a; VInt c ] -> VInt (rotate a ((width - count c) mod width))
  | Cgt.Math.Pop_count, [ VInt a ] -> VInt (Int64.of_int (ones (unsigned a) 0))
  | Cgt.Math.Leading_zeros, [ VInt a ] -> VInt (Int64.of_int (width - length (unsigned a) 0))
  | Cgt.Math.Trailing_zeros, [ VInt a ] ->
      let rec zeros a n =
        if n = width || Int64.logand a 1L = 1L then n else zeros (Int64.shift_right_logical a 1) (n + 1)
      in
      VInt (Int64.of_int (zeros (unsigned a) 0))
  | Cgt.Math.Abs, [ VInt a ] -> VInt (if Int64.compare a 0L < 0 then int t (Int64.neg a) else a)
  | Cgt.Math.Min, [ VInt a; VInt b ] -> VInt (if Int64.compare a b <= 0 then a else b)
  | Cgt.Math.Max, [ VInt a; VInt b ] -> VInt (if Int64.compare a b >= 0 then a else b)
  | Cgt.Math.Sqrt, [ VFloat a ] -> VFloat (float t (Float.sqrt a))
  | Cgt.Math.Abs, [ VFloat a ] -> VFloat (float t (Float.abs a))
  | Cgt.Math.Floor, [ VFloat a ] -> VFloat (float t (Float.floor a))
  | Cgt.Math.Ceil, [ VFloat a ] -> VFloat (float t (Float.ceil a))
  | Cgt.Math.Trunc, [ VFloat a ] -> VFloat (float t (Float.trunc a))
  | Cgt.Math.Round_even, [ VFloat a ] -> VFloat (float t (round_even a))
  | Cgt.Math.Fma, [ VFloat a; VFloat b; VFloat c ] when t = Ty.F64 -> VFloat (float t (Float.fma a b c))
  (* A NaN's sign is not the program's to see (math.md §2.5). *)
  | Cgt.Math.Copy_sign, [ VFloat m; VFloat s ] ->
      VFloat (float t (if Float.is_nan s then Float.abs m else Float.copy_sign m s))
  | Cgt.Math.Min, [ VFloat a; VFloat b ] -> VFloat (float t (least a b))
  | Cgt.Math.Max, [ VFloat a; VFloat b ] -> VFloat (float t (greatest a b))
  | _ -> stop ("`@math$" ^ Cgt.Math.name fn ^ "`, which only the running program computes")

(* A scalar converted from [from] to [into], as emit.ml's [convert]. *)
let convert (from : Ty.t) (into : Ty.t) v =
  match (from, into, v) with
  | (Ty.I32 | Ty.I64), (Ty.I32 | Ty.I64), VInt a -> VInt (int into a)
  | (Ty.I32 | Ty.I64), (Ty.F32 | Ty.F64), VInt a -> VFloat (Scalar.to_float into a)
  | (Ty.F32 | Ty.F64), (Ty.F32 | Ty.F64), VFloat a -> VFloat (float into a)
  | (Ty.F32 | Ty.F64), (Ty.I32 | Ty.I64), VFloat a ->
      let least, most = Scalar.ends into in
      if Float.is_nan a then VInt 0L
      else if Scalar.truncates_into ~from into a then VInt (Int64.of_float (Float.trunc a))
      else VInt (if a < 0. then least else most)
  | _ -> stop "a conversion of a value it does not convert"

(* ---------------------------------------------------------------------- *)
(* Expressions and statements                                             *)
(* ---------------------------------------------------------------------- *)

let rec expr run fr (e : Expr.t) : v =
  tick run;
  match e.Expr.node with
  | Expr.Int i -> VInt (int e.Expr.ty i)
  | Expr.Float f -> VFloat f
  | Expr.Bool b -> VBool b
  | Expr.Text s -> VText s
  | Expr.Unit -> VUnit
  (* A read is a copy: the local keeps what it holds whatever is done with
     what was read. *)
  | Expr.Local id ->
      sized run e.Expr.ty;
      own (local fr id).value
  | Expr.Address id -> at (local fr id)
  | Expr.Deref p | Expr.Snapshot p -> (
      let p = expr run fr p in
      match e.Expr.ty with
      | Ty.Void -> VUnit
      (* An address read out of a place is lent, though the place may hold
         it as a box: what owns a box is the value the box is in. *)
      | Ty.Ptr -> ( match load (ptr_of p) with VPtr q -> VPtr { q with owned = false } | v -> v)
      | t ->
          sized run t;
          load (ptr_of p))
  | Expr.Call { fn; args } ->
      let args = List.map (expr run fr) args in
      call run fn args
  | Expr.Call_value { fn; args } -> (
      let f = expr run fr fn in
      let args = List.map (expr run fr) args in
      match f with VFunc s -> call run s args | _ -> stop "a call through no function")
  | Expr.Runtime { fn; args } ->
      let args = List.map (expr run fr) args in
      runtime run fn args
  | Expr.Binary { op; left; right } ->
      (* The left operand runs first. *)
      let l = expr run fr left in
      let r = expr run fr right in
      binary op left.Expr.ty l r
  | Expr.Math { fn; args } -> (
      let args = List.map (expr run fr) args in
      match Intrinsics.math fn e.Expr.ty with
      | Intrinsics.Computed | Intrinsics.Output -> math fn e.Expr.ty args
      | Intrinsics.Input -> stop "an approximate math function, which only the running program has")
  | Expr.Flip value -> flip value.Expr.ty (expr run fr value)
  | Expr.Convert value -> convert value.Expr.ty e.Expr.ty (expr run fr value)
  | Expr.Expand { label; body; result } -> (
      sized run e.Expr.ty;
      Option.iter (fun id -> bind fr id e.Expr.ty (zero e.Expr.ty)) result;
      (try stats run fr body with Left l when l = label -> ());
      match result with Some id -> own (local fr id).value | None -> VUnit)
  | Expr.Record members ->
      sized run e.Expr.ty;
      let v =
        match zero e.Expr.ty with
        | VRecord a -> a
        | _ -> stop "a record of a type that is not a struct"
      in
      List.iter (fun (i, m) -> v.(i) <- expr run fr m) members;
      VRecord v
  | Expr.Member { value; index } -> (
      match (expr run fr value, index) with
      | VRecord a, i when i < Array.length a -> a.(i)
      (* A handle's middle word is its length (emit.ml lays it out as a
         pointer and two counts). *)
      | VList l, 1 -> VInt (Int64.of_int l.count)
      | VText s, 1 -> VInt (Int64.of_int (String.length s))
      | _ -> stop "a member of something that does not have it")
  | Expr.Case { index; payload } -> VCase (index, expr run fr payload)
  | Expr.Payload { value; index } -> read_path (expr run fr value) [ Payload index ]
  | Expr.Offset { base; within; path } -> VPtr (offset (ptr_of (expr run fr base)) within path)
  | Expr.Take { address; layout } -> (
      let p = ptr_of (expr run fr address) in
      match e.Expr.ty with
      | Ty.Void -> VUnit
      | t ->
          sized run t;
          let v = load p in
          store p t (vacate run.prog.layouts layout t v);
          v)
  | Expr.Copy { value; layout } ->
      let v = expr run fr value in
      bytes run (weight v);
      copy run.prog.layouts layout value.Expr.ty v
  | Expr.Box { value; layout } ->
      let v = expr run fr value in
      sized run value.Expr.ty;
      owner (cell ~layout value.Expr.ty v)
  | Expr.Layout l -> VLayout l
  | Expr.Function f -> VFunc f
  | Expr.Global g -> at (global run g)
  | Expr.Escape { value; _ } -> expr run fr value

and stats run fr body = List.iter (stat run fr) body

and stat run fr (s : Stat.t) =
  tick run;
  match s with
  | Stat.Let { id; value } | Stat.Hold { id; value; _ } ->
      let v = expr run fr value in
      sized run value.Expr.ty;
      bind fr id value.Expr.ty v
  | Stat.Scope { body; _ } -> stats run fr body
  | Stat.Assign { value; _ } when value.Expr.ty = Ty.Void -> ignore (expr run fr value)
  | Stat.Assign { place; value } ->
      let v = expr run fr value in
      let c =
        match (Locals.find_opt fr.locals place.Expr.local, place.Expr.deref, place.Expr.path) with
        (* A whole local of the function being folded can be stored into
           whether or not its value is known: the store decides it. *)
        | None, false, [] when Option.is_some fr.outer ->
            let c = cell ~origin:(Outer place.Expr.local) value.Expr.ty VNull in
            Locals.replace fr.locals place.Expr.local c;
            c
        | _ -> local fr place.Expr.local
      in
      let base = if place.Expr.deref then ptr_of c.value else { cell = c; path = []; owned = false } in
      let at = offset base place.Expr.ty place.Expr.path in
      sized run value.Expr.ty;
      store at value.Expr.ty v
  | Stat.Eval e -> ignore (expr run fr e)
  | Stat.Return e -> raise (Returned (expr run fr e))
  | Stat.If { cond; body } -> if bool_of (expr run fr cond) then stats run fr body
  | Stat.Repeat { count; body } ->
      (* The count is read once; a count below one runs the body no times. *)
      let n = int_of (expr run fr count) in
      let i = ref 0L in
      while Int64.compare !i n < 0 do
        tick run;
        stats run fr body;
        i := Int64.succ !i
      done
  | Stat.Switch { value; cases } -> (
      match expr run fr value with
      | VCase (tag, _) -> (
          match List.assoc_opt tag cases with
          | Some body -> stats run fr body
          | None -> stop "a switch with no case for its tag")
      | _ -> stop "a switch on something not a sum")
  | Stat.Leave label -> raise (Left label)
  | Stat.Store { address; value } ->
      let p = ptr_of (expr run fr address) in
      let v = expr run fr value in
      sized run value.Expr.ty;
      store p value.Expr.ty v
  | Stat.Place { address; value; layout } ->
      let p = ptr_of (expr run fr address) in
      let v = expr run fr value in
      sized run value.Expr.ty;
      store p value.Expr.ty v;
      if p.path = [] then p.cell.layout <- Some layout
  | Stat.Overwrite { address; value; layout } ->
      let p = ptr_of (expr run fr address) in
      let v = expr run fr value in
      bytes run (2 * weight v);
      store p value.Expr.ty (overwrite run.prog.layouts layout value.Expr.ty (load p) v)
  | Stat.Reserve { id; ty; _ } ->
      sized run ty;
      bind fr id ty (zero ty)
  | Stat.Spawn { task; thunk; frame; args; dest; _ } ->
      (* Run where it is spawned (O8): its arguments first, in order, then
         the call, whose result is home at once. *)
      let values = List.map (expr run fr) args in
      let held =
        match zero frame with
        | VRecord a ->
            List.iteri (fun i v -> a.(i + 1) <- v) values;
            a
        | _ -> stop "a spawned call's frame that is not a struct"
      in
      let frame_cell = cell frame (VRecord held) in
      bind fr task Ty.Ptr (Value.at frame_cell);
      ignore (call run thunk [ Value.at frame_cell ]);
      Option.iter
        (fun id ->
          let t = match frame with Ty.Struct (r :: _) -> r | _ -> Ty.Void in
          bind fr id t (read_path frame_cell.value [ Member 0 ]))
        dest
  (* A task spawned before the code being folded is still running: its
     join stays. *)
  | Stat.Join task -> ignore (local fr task)

(* ---------------------------------------------------------------------- *)
(* Calls and the runtime                                                  *)
(* ---------------------------------------------------------------------- *)

and call run fn args =
  match Funcs.find_opt run.prog.funcs fn with
  | None -> stop "a call to a function with no body here"
  | Some { func = f; _ } when f.Func.linkage = Linkage.Imported -> stop "a call to a function with no body here"
  | Some ({ func = f; _ } as e) -> (
      if List.length f.Func.params <> List.length args then stop "a call with the wrong arguments";
      (* A call made before with the same arguments gives what it gave then.
         A run that makes a constant changes what a constant's state holds,
         which a call's arguments do not say, so it remembers nothing. *)
      let key =
        if run.making = None && remembers run.prog.funcs e then
          let consts = List.map export args in
          if List.for_all Option.is_some consts then Some (fn, List.map Option.get consts) else None
        else None
      in
      match Option.bind key (Key.find_opt run.prog.memo) with
      | Some m ->
          charge_outputs run ~count:m.count ~text:m.text;
          run.outputs <- List.rev_append m.outputs run.outputs;
          import m.result
      | None ->
          run.depth <- run.depth + 1;
          if run.depth > max_depth then stop "calls nested too deep";
          (* As many locals as the last call of the function numbered. *)
          let fr = { locals = Locals.create ~size:e.frame (); outer = None } in
          List.iter2 (fun (id, ty) v -> bind fr id ty v) f.Func.params args;
          let before = run.outputs and count = run.output_count and text = run.output_bytes in
          let result = try stats run fr f.Func.body; VUnit with Returned v -> v in
          run.depth <- run.depth - 1;
          e.frame <- Locals.size fr.locals;
          (match (key, export result) with
          | Some key, Some c ->
              (* What this call output: the newest outputs, back to those
                 there were before it. *)
              let rec since acc l =
                if l == before then acc else match l with x :: r -> since (x :: acc) r | [] -> acc
              in
              Key.replace run.prog.memo key
                {
                  result = c;
                  outputs = since [] run.outputs;
                  count = run.output_count - count;
                  text = run.output_bytes - text;
                }
          | _ -> ());
          result)

and runtime run (fn : Cgt.Runtime.fn) args =
  match (Intrinsics.classify fn, fn, args) with
  | Intrinsics.Input, _, _ -> stop "an input, which only the running program has"
  | _, Cgt.Runtime.Print, [ text ] ->
      output run (Print (text_of text));
      VUnit
  | _, Cgt.Runtime.Set_threads, [ count ] ->
      let n = int_of count in
      output run (Set_threads n);
      VInt (if Int64.compare n 1L < 0 then 0L else 1L)
  | _, Cgt.Runtime.Set_threads_auto, [] ->
      output run Set_threads_auto;
      VUnit
  | _, Cgt.Runtime.Text_join, [ l; r ] ->
      let l = text_of l and r = text_of r in
      bytes run (String.length l + String.length r);
      VText (l ^ r)
  | _, Cgt.Runtime.Text_equal, [ l; r ] ->
      let l = text_of l and r = text_of r in
      bytes run (min (String.length l) (String.length r));
      VInt (if String.equal l r then 1L else 0L)
  | _, Cgt.Runtime.Text_i32, [ VInt i ]
  | _, Cgt.Runtime.Text_i64, [ VInt i ] ->
      let text = Int64.to_string i in
      bytes run (String.length text);
      VText text
  | _, Cgt.Runtime.Text_f32, [ VFloat f ] ->
      let text = float_text Ty.F32 f in
      bytes run (String.length text);
      VText text
  | _, Cgt.Runtime.Text_f64, [ VFloat f ] ->
      let text = float_text Ty.F64 f in
      bytes run (String.length text);
      VText text
  | _, Cgt.Runtime.Parse_i64, [ text; out ] -> (
      let text = text_of text in
      bytes run (String.length text);
      match parse_i64 text with
      | Some n ->
          store (ptr_of out) Ty.I64 (VInt n);
          VInt 1L
      | None -> VInt 0L)
  | _, Cgt.Runtime.Parse_f64, [ text; out ] -> (
      let text = text_of text in
      bytes run (String.length text);
      match parse_f64 text with
      | Some f ->
          store (ptr_of out) Ty.F64 (VFloat f);
          VInt 1L
      | None -> VInt 0L)
  | _, Cgt.Runtime.List_new, [] -> empty ()
  | _, Cgt.Runtime.List_push, [ list; stride ] -> (
      match load (ptr_of list) with
      | VList l ->
          l.stride <- Int64.to_int (int_of stride);
          if l.count = Array.length l.items then begin
            bytes run (8 * l.count);
            l.items <-
              Array.init (max 4 (2 * l.count)) (fun i -> if i < l.count then l.items.(i) else cell Ty.Void VNull)
          end;
          let c = cell Ty.Void VNull in
          l.items.(l.count) <- c;
          l.count <- l.count + 1;
          at c
      | _ -> stop "a push onto something not a list")
  | _, Cgt.Runtime.List_at, [ list; index; _stride ] -> (
      let i = int_of index in
      match load (ptr_of list) with
      | VList l when Int64.compare i 1L >= 0 && Int64.compare i (Int64.of_int l.count) <= 0 ->
          at l.items.(Int64.to_int i - 1)
      | VList _ -> stop "an index out of range"
      | _ -> stop "an element of something not a list")
  (* The element at [index] has moved out: the list closes over its cell. *)
  | _, ((Cgt.Runtime.List_remove | Cgt.Runtime.List_swap_remove) as fn), [ list; index; _ ] -> (
      let i = Int64.to_int (int_of index) - 1 in
      match load (ptr_of list) with
      | VList l when i >= 0 && i < l.count ->
          let last = l.count - 1 in
          if fn = Cgt.Runtime.List_remove then begin
            bytes run (8 * (last - i));
            Array.blit l.items (i + 1) l.items i (last - i)
          end
          else l.items.(i) <- l.items.(last);
          l.items.(last) <- cell Ty.Void VNull;
          l.count <- last;
          VUnit
      | VList _ -> stop "an index out of range"
      | _ -> stop "a removal from something not a list")
  | _, Cgt.Runtime.Array_at, [ array; index; count; _stride ] ->
      let i = int_of index in
      if Int64.compare i 1L < 0 || Int64.compare i (int_of count) > 0 then stop "an index out of range";
      let p = ptr_of array in
      VPtr { p with path = p.path @ [ Member (Int64.to_int i - 1) ] }
  (* Where a constant is made, whether this is the first read is a fact of
     the running program, not of the code: the read stays. A read inside a
     call is the whole call, which folds when the constant does. *)
  | _, (Cgt.Runtime.Constant_begin | Cgt.Runtime.Constant_end), _
    when run.depth = 0 && run.making = None ->
      stop "where a package constant is made"
  | _, Cgt.Runtime.Constant_begin, [ state ] -> (
      let p = ptr_of state in
      match load p with
      | VInt -1L -> VInt 0L
      | VInt 0L ->
          store p Ty.I64 (VInt 1L);
          VInt 1L
      | VInt _ -> stop "a package constant read while it is made"
      | _ -> stop "a package constant that does not fold")
  | _, Cgt.Runtime.Constant_end, [ state; _value; _layout ] ->
      store (ptr_of state) Ty.I64 (VInt (-1L));
      VUnit
  | _, Cgt.Runtime.Writeback, [ target; copy; _size; _layout ] ->
      let from = ptr_of copy in
      store (ptr_of target) from.cell.ty (load from);
      VUnit
  | _ -> stop "a runtime call the tree does not make"
