(* Stage 5's evaluator (docs/design/optimization.md): its literals and
   arithmetic, which are codegen's, what it folds, what it makes back into
   code, and the bounds it keeps to. *)

module Value = Optimize__Value
module Eval = Optimize__Eval
module Fold = Optimize__Fold
module Materialize = Optimize__Materialize
module Intrinsics = Optimize__Intrinsics

open Support
open Cgt_terms

let stops f = match f () with _ -> false | exception Value.Stop _ -> true

(* The evaluator's arithmetic is codegen's (lib/codegen/emit.ml). *)
(* An F32 literal rounds once, from the decimal straight to the single
   (Tst.Decimal): where the double nearest the literal is the midpoint of two
   singles, the literal's own side of that midpoint determines the result. *)
let single_literals () =
  let bits text = Int32.bits_of_float (Tst.Decimal.to_single text) in
  check "a literal just above a midpoint rounds up"
    (bits "1.0000000596046447753906250000000000000000000000000000000000000000000000000000000000000000000000000001"
    = 0x3f800001l);
  check "a literal just below a midpoint rounds down"
    (bits "1.0000000596046447753906249999999999999999999999999999999999999999999999999999999999999999999999999999"
    = 0x3f800000l);
  check "a literal on a midpoint rounds to even" (bits "1.000000059604644775390625" = 0x3f800000l);
  check "an ordinary literal is the nearest single" (bits "0.1" = Int32.bits_of_float 0.1);
  check "a literal on the midpoint past the largest single overflows"
    (Tst.Decimal.to_single "340282356779733661637539395458142568448.0" = Float.infinity);
  check "a literal just below that midpoint is the largest single"
    (bits "340282356779733661637539395458142568447.9" = 0x7f7fffffl)

let folded_arithmetic () =
  let i32 n = Value.VInt (Value.int C.Ty.I32 n) and i64 n = Value.VInt n in
  let bin op t l r = Eval.binary op t l r in
  check "I32 wraps on +"
    (bin C.Expr.Add C.Ty.I32 (i32 2147483647L) (i32 1L) = i32 (-2147483648L));
  check "I32 wraps on *" (bin C.Expr.Mul C.Ty.I32 (i32 65536L) (i32 65536L) = i32 0L);
  check "I32's most negative over -1 wraps"
    (bin C.Expr.Div C.Ty.I32 (i32 (-2147483648L)) (i32 (-1L)) = i32 (-2147483648L));
  check "I64's most negative over -1 wraps"
    (bin C.Expr.Div C.Ty.I64 (i64 Int64.min_int) (i64 (-1L)) = i64 Int64.min_int);
  check "integer division truncates" (bin C.Expr.Div C.Ty.I64 (i64 (-7L)) (i64 2L) = i64 (-3L));
  check "an integer division by zero gives zero" (bin C.Expr.Div C.Ty.I64 (i64 1L) (i64 0L) = i64 0L);
  let conv from into v = Eval.convert from into v in
  check "a NaN truncates to zero" (conv C.Ty.F64 C.Ty.I32 (Value.VFloat Float.nan) = i32 0L);
  check "a truncation above an I32 saturates"
    (conv C.Ty.F64 C.Ty.I32 (Value.VFloat 2147483648.) = i32 2147483647L);
  check "a truncation below an I64 saturates"
    (conv C.Ty.F32 C.Ty.I64 (Value.VFloat Float.neg_infinity) = i64 Int64.min_int);
  let f x = Value.VFloat x in
  check "NaN is not equal to itself" (bin C.Expr.Eq C.Ty.F64 (f Float.nan) (f Float.nan) = Value.VBool false);
  check "NaN is not less than anything" (bin C.Expr.Less C.Ty.F64 (f Float.nan) (f 1.) = Value.VBool false);
  check "negative zero equals zero" (bin C.Expr.Eq C.Ty.F64 (f (-0.)) (f 0.) = Value.VBool true);
  check "Bool + is or" (bin C.Expr.Add C.Ty.I1 (Value.VBool true) (Value.VBool false) = Value.VBool true);
  check "Bool * is and" (bin C.Expr.Mul C.Ty.I1 (Value.VBool true) (Value.VBool false) = Value.VBool false);
  check "~ wraps the most negative I32" (Eval.flip C.Ty.I32 (i32 (-2147483648L)) = i32 (-2147483648L))

(* Every runtime function is in a class, and the outputs are the three
   docs/design/optimization.md O3 names. The program's arguments are the one
   input an intrinsic reads; a worker's wait, which no replay could keep,
   the stop when C returns no handle, the end of the program when `main`
   aborts, the context a thread C started is given, and a worker pool's
   work, which runs beside the code after it, are the others. *)
let intrinsic_classes () =
  let outputs =
    List.filter (fun fn -> Intrinsics.classify fn = Intrinsics.Output) Cgt.Runtime.all
  in
  check "print and the thread count are the outputs"
    (List.sort compare outputs
    = List.sort compare Cgt.Runtime.[ Print; Set_threads; Set_threads_auto ]);
  check "the program's arguments, the clock, a worker's wait, an abort of `main`, a null foreign handle, a callback's context, a worker pool's operations, the experimental pooled variants and the experimental byte and range list operations are the inputs"
    (List.filter (fun fn -> Intrinsics.classify fn = Intrinsics.Input) Cgt.Runtime.all
    = Cgt.Runtime.[ Text_bytes; List_append; List_copy; List_same; List_hash; List_sort; List_sort_by; Byte_set; Text_find_pair; Text_find_any; Text_hash; Main_aborted; Tick_start; Tick; Arguments; Monotonic_ns; Pool_new; Pool_push; Pool_append; Pool_root; Pool_copy; Link; Pool_reserve; Pool_new_unbounded; No_object; Callback_attach; Callback_detach; Workers_new; Workers_start; Workers_publish; Workers_state; Workers_elements ])

(* The math functions of `@math$` as the evaluator folds them (math.md §2),
   which the math codegen fixture holds both builds to as well, and which
   of them fold at all. *)
let folded_math () =
  let i32 n = Value.VInt (Value.int C.Ty.I32 n) and i64 n = Value.VInt n in
  let f x = Value.VFloat x in
  let m fn t args = Eval.math fn t args in
  let sign_bit = function Value.VFloat x -> Float.sign_bit x | _ -> false in
  let is_nan = function Value.VFloat x -> Float.is_nan x | _ -> false in
  check "a shift count is taken modulo the width"
    (m Cgt.Math.Shift_left C.Ty.I64 [ i64 1L; i64 65L ] = i64 2L
    && m Cgt.Math.Shift_left C.Ty.I32 [ i32 1L; i32 32L ] = i32 1L
    && m Cgt.Math.Shift_left C.Ty.I64 [ i64 1L; i64 (-1L) ] = i64 Int64.min_int);
  check "a logical shift of an I32 fills with zeros"
    (m Cgt.Math.Shift_right_logical C.Ty.I32 [ i32 (-1L); i32 28L ] = i32 15L);
  check "an arithmetic shift keeps the sign"
    (m Cgt.Math.Shift_right C.Ty.I32 [ i32 (-2147483648L); i32 31L ] = i32 (-1L));
  check "a rotation brings back what it moves out"
    (m Cgt.Math.Rotate_left C.Ty.I32 [ i32 (-2147483648L); i32 1L ] = i32 1L
    && m Cgt.Math.Rotate_right C.Ty.I64 [ i64 1L; i64 1L ] = i64 Int64.min_int
    && m Cgt.Math.Rotate_left C.Ty.I64 [ i64 5L; i64 64L ] = i64 5L);
  check "zero's leading and trailing zeros are the width"
    (m Cgt.Math.Leading_zeros C.Ty.I32 [ i32 0L ] = i32 32L
    && m Cgt.Math.Trailing_zeros C.Ty.I64 [ i64 0L ] = i64 64L);
  check "a population count reads an I32's 32 bits"
    (m Cgt.Math.Pop_count C.Ty.I32 [ i32 (-1L) ] = i32 32L);
  check "abs wraps on the most negative value"
    (m Cgt.Math.Abs C.Ty.I32 [ i32 (-2147483648L) ] = i32 (-2147483648L));
  check "roundEven takes a tie to the even neighbour"
    (m Cgt.Math.Round_even C.Ty.F64 [ f 2.5 ] = f 2.
    && m Cgt.Math.Round_even C.Ty.F64 [ f (-3.5) ] = f (-4.)
    && sign_bit (m Cgt.Math.Round_even C.Ty.F64 [ f (-0.5) ]));
  check "min and max let a NaN through"
    (is_nan (m Cgt.Math.Min C.Ty.F64 [ f Float.nan; f 1. ])
    && is_nan (m Cgt.Math.Max C.Ty.F32 [ f 1.; f Float.nan ]));
  check "min orders a negative zero first"
    (sign_bit (m Cgt.Math.Min C.Ty.F64 [ f 0.; f (-0.) ])
    && not (sign_bit (m Cgt.Math.Max C.Ty.F64 [ f (-0.); f 0. ])));
  check "copySign takes a NaN's sign as positive"
    (m Cgt.Math.Copy_sign C.Ty.F64 [ f (-3.); f (Float.neg Float.nan) ] = f 3.);
  check "fma rounds once"
    (let a = 1. +. Float.pow 2. (-27.) in
     m Cgt.Math.Fma C.Ty.F64 [ f a; f a; f (-1.) ] = f (Float.pow 2. (-26.) +. Float.pow 2. (-54.)));
  check "an F32 sqrt is rounded to a single"
    (m Cgt.Math.Sqrt C.Ty.F32 [ f 2. ] = f (Int32.float_of_bits (Int32.bits_of_float (Float.sqrt 2.))));
  check "the approximate functions and an F32 fma are inputs, the rest computed"
    (List.for_all
       (fun fn ->
         let expected t =
           if Cgt.Math.exact fn && not (fn = Cgt.Math.Fma && t = C.Ty.F32) then Intrinsics.Computed
           else Intrinsics.Input
         in
         List.for_all (fun t -> Intrinsics.math fn t = expected t) C.Ty.[ I32; I64; F32; F64 ])
       Cgt.Math.all
    && List.filter (fun fn -> not (Cgt.Math.exact fn)) Cgt.Math.all
       = Cgt.Math.[ Cbrt; Sin; Cos; Tan; Asin; Acos; Atan; Atan2; Exp; Log; Pow; Hypot ])

(* What `parseI64` and `parseF64` read (types.md §2.10), as the evaluator
   folds them; runtime/block.c reads the same text the same way. *)
let parsed_numbers () =
  check "an integer's digits" (Eval.parse_i64 "42" = Some 42L);
  check "a leading -" (Eval.parse_i64 "-7" = Some (-7L));
  check "leading zeros" (Eval.parse_i64 "007" = Some 7L);
  check "the largest I64" (Eval.parse_i64 "9223372036854775807" = Some Int64.max_int);
  check "the smallest I64" (Eval.parse_i64 "-9223372036854775808" = Some Int64.min_int);
  check "past the largest I64" (Eval.parse_i64 "9223372036854775808" = None);
  check "no text" (Eval.parse_i64 "" = None);
  check "a - alone" (Eval.parse_i64 "-" = None);
  check "no +" (Eval.parse_i64 "+5" = None);
  check "no whitespace" (Eval.parse_i64 " 5" = None && Eval.parse_i64 "5 " = None);
  check "no separators" (Eval.parse_i64 "1_000" = None);
  check "no hex" (Eval.parse_i64 "0x10" = None);
  check "no fraction for an integer" (Eval.parse_i64 "3.25" = None);
  check "a float's digits" (Eval.parse_f64 "3.25" = Some 3.25);
  check "an integer as a float" (Eval.parse_f64 "-7" = Some (-7.));
  check "a negative zero" (Eval.parse_f64 "-0.0" = Some (-0.));
  check "nearest, half to even" (Eval.parse_f64 "9007199254740993" = Some 9007199254740992.);
  check "a digit on each side of the ." (Eval.parse_f64 "3." = None && Eval.parse_f64 ".5" = None);
  check "no exponent" (Eval.parse_f64 "1e5" = None);
  check "no nan or inf" (Eval.parse_f64 "nan" = None && Eval.parse_f64 "inf" = None);
  check "too large to be finite" (Eval.parse_f64 ("1" ^ String.make 400 '0') = None)


(* A value made back into code, and read back, is the value it was. *)
let materialized () =
  let t = C.Ty.Sum [ C.Ty.Struct [ C.Ty.I64; C.Ty.Handle ]; C.Ty.Void ] in
  let c = Value.Case (0, Value.Record [| Value.Int 3L; Value.Text "hi" |]) in
  check "a variant of a struct is code and back"
    (Option.bind (Materialize.expr t c) Materialize.const = Some c);
  check "a string is no function's address" (Materialize.expr C.Ty.Ptr (Value.Text "x") = None)
  ;
  let bytes = C.Ty.Struct [ C.Ty.I8; C.Ty.I64 ] in
  let b = Value.Record [| Value.Int 200L; Value.Int 7L |] in
  check "a struct holding a byte is code and back" (Option.bind (Materialize.expr bytes b) Materialize.const = Some b)

(* Calls run, outputs are kept in order, a call made again is remembered
   when a loop or work that grows with a value is reachable from it, and a budget spent or a constant made where it is read stops the run. *)
let evaluated () =
  let print s = C.Stat.Eval (e (C.Expr.Runtime { fn = Cgt.Runtime.Print; args = [ e (C.Expr.Text s) C.Ty.Handle ] }) C.Ty.Void) in
  let double =
    func "double" [ (1, C.Ty.I64) ]
      [ print "a"; print "b"; C.Stat.Return (e (C.Expr.Binary { op = C.Expr.Mul; left = e (C.Expr.Local 1) C.Ty.I64; right = i64 2L }) C.Ty.I64) ]
  in
  let twice =
    func "twice" [ (1, C.Ty.I64) ]
      [
        C.Stat.Repeat { count = i64 1L; body = [] };
        C.Stat.Return (e (C.Expr.Call { fn = "double"; args = [ e (C.Expr.Local 1) C.Ty.I64 ] }) C.Ty.I64);
      ]
  in
  let join =
    let text = e (C.Expr.Local 1) C.Ty.Handle in
    func "join" [ (1, C.Ty.Handle) ]
      [ C.Stat.Return (e (C.Expr.Runtime { fn = Cgt.Runtime.Text_join; args = [ text; text ] }) C.Ty.Handle) ]
  in
  let next =
    func "next" [ (1, C.Ty.I64) ]
      [ C.Stat.Return (e (C.Expr.Binary { op = C.Expr.Add; left = e (C.Expr.Local 1) C.Ty.I64; right = i64 1L }) C.Ty.I64) ]
  in
  let long =
    let x = e (C.Expr.Local 1) C.Ty.I64 in
    let sum = List.fold_left (fun acc _ -> e (C.Expr.Binary { op = C.Expr.Add; left = acc; right = x }) C.Ty.I64) x (List.init 40 Fun.id) in
    func "long" [ (1, C.Ty.I64) ] [ C.Stat.Return sum ]
  in
  let self =
    func "self" [ (1, C.Ty.I64) ] [ C.Stat.Return (e (C.Expr.Call { fn = "self"; args = [ e (C.Expr.Local 1) C.Ty.I64 ] }) C.Ty.I64) ]
  in
  let zeroes =
    func "zeroes" [ (1, C.Ty.I64) ]
      [ C.Stat.Reserve { id = 2; scope = 0; ty = C.Ty.Array (C.Ty.I64, 8191); layout = "a" }; C.Stat.Return (i64 0L) ]
  in
  let prog = program [ double; twice; join; next; long; self; zeroes ] in
  let asked f = Eval.remembers prog.Eval.funcs (Eval.Funcs.find prog.Eval.funcs f) in
  check "a small body that calls itself is remembered" (asked "self");
  check "as is a small body that reserves a large aggregate" (asked "zeroes");
  let run = Eval.start prog in
  check "a call gives its result" (Eval.call run "twice" [ Value.VInt 21L ] = Value.VInt 42L);
  check "outputs are kept in the order made" (List.rev run.Eval.outputs = Eval.[ Print "a"; Print "b" ]);
  check "a call is remembered by its arguments" (Value.Key.mem prog.Eval.memo ("twice", [ Value.Int 21L ]));
  ignore (Eval.call run "long" [ Value.VInt 1L ]);
  check "as is a call to a large body, though it neither loops nor calls"
    (Value.Key.mem prog.Eval.memo ("long", [ Value.Int 1L ]));
  ignore (Eval.call run "next" [ Value.VInt 1L ]);
  check "a call that reaches no loop, recursion or runtime function is not"
    (not (Value.Key.mem prog.Eval.memo ("next", [ Value.Int 1L ])));
  ignore (Eval.call run "join" [ Value.VText "ab" ]);
  check "as is a call whose work grows with its arguments"
    (Value.Key.mem prog.Eval.memo ("join", [ Value.Text "ab" ]));
  (* f30 calls f29 twice, and so on down, which is 2^30 calls unless each
     level is remembered. *)
  let level k =
    let call = e (C.Expr.Call { fn = Printf.sprintf "f%d" (k - 1); args = [ e (C.Expr.Local 1) C.Ty.I64 ] }) C.Ty.I64 in
    func (Printf.sprintf "f%d" k) [ (1, C.Ty.I64) ]
      [ C.Stat.Return (e (C.Expr.Binary { op = C.Expr.Add; left = call; right = call }) C.Ty.I64) ]
  in
  let leaf = func "f0" [ (1, C.Ty.I64) ] [ C.Stat.Return (e (C.Expr.Local 1) C.Ty.I64) ] in
  let doubling = program (leaf :: List.init 30 (fun k -> level (k + 1))) in
  let link k =
    let call = e (C.Expr.Call { fn = Printf.sprintf "f%d" (k - 1); args = [ e (C.Expr.Local 1) C.Ty.I64 ] }) C.Ty.I64 in
    func (Printf.sprintf "f%d" k) [ (1, C.Ty.I64) ] [ C.Stat.Return call ]
  in
  let chain = program (leaf :: List.init 100 (fun k -> link (k + 1))) in
  ignore (Eval.call (Eval.start chain) "f100" [ Value.VInt 1L ]);
  let remembered k = Value.Key.mem chain.Eval.memo (Printf.sprintf "f%d" k, [ Value.Int 1L ]) in
  check "a long chain of small bodies, each making one call, is remembered every 64 nodes or so"
    (List.exists remembered (List.init 30 (fun k -> k + 1)) && not (remembered 1));
  check "a body making two calls is remembered, so their doubling stays linear"
    (match Eval.call (Eval.start doubling) "f30" [ Value.VInt 1L ] with
     | v -> v = Value.VInt 1073741824L
     | exception Value.Stop _ -> false);
  let again = Eval.start prog in
  ignore (Eval.call again "twice" [ Value.VInt 21L ]);
  check "a remembered call outputs again" (List.rev again.Eval.outputs = Eval.[ Print "a"; Print "b" ]);
  let forever = C.Stat.Repeat { count = i64 Int64.max_int; body = [] } in
  let fr = { Eval.locals = Eval.Locals.create (); outer = None } in
  check "a spent budget stops the run" (stops (fun () -> Eval.stat (Eval.start prog) fr forever));
  let state = e (C.Expr.Global "k.state") C.Ty.Ptr in
  let begin_ = e (C.Expr.Runtime { fn = Cgt.Runtime.Constant_begin; args = [ state ] }) C.Ty.I64 in
  check "where a constant is made stays" (stops (fun () -> Eval.expr (Eval.start prog) fr begin_))

let formatted_scalars () =
  let run = Eval.start (program []) in
  let format fn value =
    match Eval.runtime run fn [ value ] with Value.VText text -> text | _ -> ""
  in
  check "I32 formats as decimal"
    (format Cgt.Runtime.Text_i32 (Value.VInt (-2147483648L)) = "-2147483648");
  check "I64 formats as decimal"
    (format Cgt.Runtime.Text_i64 (Value.VInt Int64.min_int) = "-9223372036854775808");
  check "F32 uses a shortest round-tripping decimal"
    (format Cgt.Runtime.Text_f32 (Value.VFloat (C.Scalar.single 0.1)) = "0.1");
  check "F64 uses a shortest round-tripping decimal"
    (format Cgt.Runtime.Text_f64 (Value.VFloat (1. /. 3.)) = "0.3333333333333333");
  List.iter
    (fun fn -> check "10 uses shorter fixed notation" (format fn (Value.VFloat 10.) = "10"))
    [ Cgt.Runtime.Text_f32; Cgt.Runtime.Text_f64 ];
  check "scientific notation can beat %g's fixed spelling"
    (format Cgt.Runtime.Text_f64 (Value.VFloat 0.0001) = "1e-4");
  check "F32 subnormals round-trip"
    (format Cgt.Runtime.Text_f32 (Value.VFloat (Int32.float_of_bits 1l)) = "1e-45");
  check "F64 subnormals round-trip"
    (format Cgt.Runtime.Text_f64 (Value.VFloat (Int64.float_of_bits 1L)) = "5e-324");
  check "negative zero keeps its sign"
    (format Cgt.Runtime.Text_f32 (Value.VFloat (-0.)) = "-0");
  check "float specials have fixed spellings"
    (format Cgt.Runtime.Text_f64 (Value.VFloat Float.infinity) = "inf"
    && format Cgt.Runtime.Text_f64 (Value.VFloat Float.neg_infinity) = "-inf"
    && format Cgt.Runtime.Text_f64 (Value.VFloat Float.nan) = "nan")

(* A store writes in place, and a value read before it keeps what it read,
   as a copy at run time would. *)
let stored_in_place () =
  let c = Value.cell (C.Ty.Array (C.Ty.I64, 3)) (Value.VRecord [| Value.VInt 1L; Value.VInt 2L; Value.VInt 3L |]) in
  let whole = { Value.cell = c; path = []; owned = false } in
  let before = Value.load whole in
  Value.store { whole with path = [ Value.Member 1 ] } C.Ty.I64 (Value.VInt 9L);
  check "a store writes the element" (Value.load whole = Value.VRecord [| Value.VInt 1L; Value.VInt 9L; Value.VInt 3L |]);
  check "a value read before the store keeps what it read"
    (before = Value.VRecord [| Value.VInt 1L; Value.VInt 2L; Value.VInt 3L |])

(* A store made inside an expression that folds is kept, since code the
   fold leaves in place may read the local. *)
let kept_store () =
  let local = e (C.Expr.Local 1) C.Ty.I64 in
  let bump =
    e
      (C.Expr.Expand
         {
           label = 10;
           body =
             [
               C.Stat.assign 1 (e (C.Expr.Binary { op = C.Expr.Add; left = local; right = i64 1L }) C.Ty.I64);
               C.Stat.assign 11 local;
             ];
           result = Some 11;
         })
      C.Ty.I64
  in
  let body =
    [
      C.Stat.Let { id = 1; value = i64 5L };
      C.Stat.Eval (e (C.Expr.Binary { op = C.Expr.Add; left = bump; right = i64 0L }) C.Ty.I64);
      C.Stat.Eval (e (C.Expr.Call { fn = "opaque"; args = [ e (C.Expr.Address 1) C.Ty.Ptr ] }) C.Ty.Void);
    ]
  in
  let f = Fold.func (program []) (Value.Key.create 1) (func "f" [] body) in
  let stored = ref false in
  Fold.iter_stats f.C.Func.body ~expr:ignore ~stat:(function
    | C.Stat.Assign { place = { local = 1; path = []; _ }; value = { C.Expr.node = C.Expr.Int 6L; _ } } -> stored := true
    | _ -> ());
  check "a store inside a folded expression is kept" !stored

(* A loop over a known local leaves only what it wrote. *)
let folded_function () =
  let local = e (C.Expr.Local 1) C.Ty.I64 in
  let body =
    [
      C.Stat.Let { id = 1; value = i64 2L };
      C.Stat.Repeat
        { count = i64 3L; body = [ C.Stat.assign 1 (e (C.Expr.Binary { op = C.Expr.Mul; left = local; right = i64 2L }) C.Ty.I64) ] };
      C.Stat.Return local;
    ]
  in
  let f = Fold.func (program []) (Value.Key.create 1) (func "f" [] body) in
  check "a loop over a known local folds to what it wrote"
    (f.C.Func.body = [ C.Stat.Let { id = 1; value = i64 2L }; C.Stat.assign 1 (i64 16L); C.Stat.Return (i64 16L) ])

(* Code left to run forgets the locals it can reach: one whose address it
   is given, a value reached through a pointer local it is given, and one
   whose address was stored or came back in a call's result, but not a
   value it is given no address of. A store through the pointer local
   leaves it standing for its local. A local not marked as a value is
   reached by any call. *)
let reached_locals () =
  let local i = e (C.Expr.Local i) C.Ty.I64 and address i = e (C.Expr.Address i) C.Ty.Ptr in
  let call fn args = C.Stat.Eval (e (C.Expr.Call { fn; args }) C.Ty.Void) in
  let body =
    [
      C.Stat.Let { id = 1; value = i64 5L };
      C.Stat.Let { id = 2; value = i64 0L };
      C.Stat.Let { id = 3; value = i64 0L };
      C.Stat.Let { id = 4; value = address 3 };
      C.Stat.Assign
        { place = { local = 4; deref = true; ty = C.Ty.I64; path = [] }; value = i64 1L };
      call "keep" [ e (C.Expr.Record [ (0, address 2) ]) (C.Ty.Struct [ C.Ty.Ptr ]) ];
      C.Stat.Let { id = 5; value = i64 0L };
      C.Stat.Let
        {
          id = 6;
          value = e (C.Expr.Call { fn = "pick"; args = [ address 5 ] }) (C.Ty.Struct [ C.Ty.Ptr ]);
        };
      C.Stat.assign 2 (i64 7L);
      C.Stat.assign 3 (i64 9L);
      C.Stat.assign 5 (i64 3L);
      call "opaque" [ address 1 ];
      call "use" [ local 1 ];
      call "use" [ local 2 ];
      call "use" [ local 3 ];
      call "use" [ local 5 ];
      call "opaque" [ e (C.Expr.Local 4) C.Ty.Ptr ];
      call "use" [ local 3 ];
    ]
  in
  let used values =
    let f = Fold.func (program []) (Value.Key.create 1) (func ~values "f" [] body) in
    List.filter_map
      (function
        | C.Stat.Eval { C.Expr.node = C.Expr.Call { fn = "use"; args = [ a ] }; _ } -> Some a
        | _ -> None)
      f.C.Func.body
  in
  check "a value given no address of stays known past a call; the others do not"
    (used [ 1; 2; 3; 5 ] = [ local 1; local 2; i64 9L; local 5; local 3 ]);
  check "a local not marked as a value is forgotten by any call"
    (used [ 1; 2 ] = [ local 1; local 2; local 3; local 5; local 3 ])

(* A local bound by a [Let] whose value owns a box is not stored back by an
   assignment, which would leave the box behind: the loop that changes it
   stays. Held, the same value is stored back by an overwrite. *)
let boxes_stored_back () =
  let sum = C.Ty.Sum [ C.Ty.Void; C.Ty.Ptr ] in
  let case i payload = e (C.Expr.Case { index = i; payload }) sum in
  let boxed v = e (C.Expr.Box { value = v; layout = "chain" }) C.Ty.Ptr in
  let none = case 0 (e C.Expr.Unit C.Ty.Void) in
  let deeper = C.Stat.assign 1 (case 1 (boxed (case 1 (boxed none)))) in
  let loop = C.Stat.Repeat { count = i64 1L; body = [ deeper ] } in
  let use =
    C.Stat.Eval (e (C.Expr.Call { fn = "use"; args = [ e (C.Expr.Local 1) sum ] }) C.Ty.Void)
  in
  let body bind = [ bind; loop; use; C.Stat.Return (i64 0L) ] in
  let fold bind =
    let f = func ~values:[ 1 ] "f" [] (body bind) in
    (Fold.func (program []) (Value.Key.create 1) f).C.Func.body
  in
  let overwritten =
    List.exists (function
      | C.Stat.Overwrite { address = { C.Expr.node = C.Expr.Address 1; _ }; _ } -> true
      | _ -> false)
  in
  check "a let that owns a box keeps the loop that changes it"
    (List.exists
       (function C.Stat.Repeat _ -> true | _ -> false)
       (fold (C.Stat.Let { id = 1; value = case 1 (boxed none) })));
  check "a held value that owns a box is overwritten"
    (overwritten
       (fold (C.Stat.Hold { id = 1; scope = 0; value = case 1 (boxed none); layout = "chain" })))

(* A call's value and its outputs together count against the size cap,
   though each fits alone. *)
let capped_replacement () =
  let text = e (C.Expr.Text (String.make 40_000 'x')) C.Ty.Handle in
  let loud =
    { (func "loud" [] [ C.Stat.Eval (e (C.Expr.Runtime { fn = Cgt.Runtime.Print; args = [ text ] }) C.Ty.Void); C.Stat.Return text ])
      with C.Func.ret = C.Ty.Handle }
  in
  let call = e (C.Expr.Call { fn = "loud"; args = [] }) C.Ty.Handle in
  let f = Fold.func (program [ loud ]) (Value.Key.create 1) (func "f" [] [ C.Stat.Return call ]) in
  check "a value and outputs past the size cap together stay a call" (f.C.Func.body = [ C.Stat.Return call ])

(* A string that doubles costs steps by its size, so a few steps cannot
   build one past what the budget allows, even in a function nothing
   calls. *)
let bounded_allocation () =
  let s = e (C.Expr.Local 1) C.Ty.Handle in
  let double = e (C.Expr.Runtime { fn = Cgt.Runtime.Text_join; args = [ s; s ] }) C.Ty.Handle in
  let loop = C.Stat.Repeat { count = i64 40L; body = [ C.Stat.assign 1 double ] } in
  let body = [ C.Stat.Let { id = 1; value = e (C.Expr.Text "x") C.Ty.Handle }; loop; C.Stat.Return s ] in
  let f = Fold.func (program []) (Value.Key.create 1) (func "huge" [] body) in
  check "a string doubled past the budget stays a loop" (List.mem loop f.C.Func.body)

(* [f ()], or [None] once it has allocated about [words] words: a run whose
   allocation nothing bounds fails rather than exhausting the machine. *)
let within_allocation ~words f =
  let exception Spent in
  let rate = 1e-4 and sampled = ref 0 in
  let count (a : Gc.Memprof.allocation) =
    sampled := !sampled + a.Gc.Memprof.n_samples;
    if Float.of_int !sampled > Float.of_int words *. rate then raise Spent;
    None
  in
  let _ = Gc.Memprof.start ~sampling_rate:rate { Gc.Memprof.null_tracker with alloc_minor = count; alloc_major = count } in
  Fun.protect ~finally:Gc.Memprof.stop (fun () -> try Some (f ()) with Spent -> None)

(* A call that makes its previous level twice and prints once at the base
   is remembered after its first call, and each replay of its outputs is
   charged, so forty levels stop at the output cap rather than make 2^40
   outputs, and the call stays. Outputs with no text count too. *)
let replayed_outputs () =
  let n = e (C.Expr.Local 1) C.Ty.I64 in
  let tree word =
    let print = C.Stat.Eval (e (C.Expr.Runtime { fn = Cgt.Runtime.Print; args = [ e (C.Expr.Text word) C.Ty.Handle ] }) C.Ty.Void) in
    let below = e (C.Expr.Binary { op = C.Expr.Add; left = n; right = i64 (-1L) }) C.Ty.I64 in
    let again = C.Stat.Eval (e (C.Expr.Call { fn = "tree"; args = [ below ] }) C.Ty.I64) in
    let base = e (C.Expr.Binary { op = C.Expr.Eq; left = n; right = i64 0L }) C.Ty.I1 in
    func "tree" [ (1, C.Ty.I64) ] [ C.Stat.If { cond = base; body = [ print; C.Stat.Return (i64 0L) ] }; again; again; C.Stat.Return (i64 0L) ]
  in
  List.iter
    (fun word ->
      let prog = program [ tree word ] in
      let run = Eval.start prog in
      let stopped = within_allocation ~words:50_000_000 (fun () -> stops (fun () -> Eval.call run "tree" [ Value.VInt 40L ])) in
      check (Printf.sprintf "forty levels printing %S stop at the output cap" word) (stopped = Some true);
      let call = e (C.Expr.Call { fn = "tree"; args = [ i64 40L ] }) C.Ty.I64 in
      let folded =
        within_allocation ~words:50_000_000 (fun () -> Fold.func prog (Value.Key.create 1) (func "f" [] [ C.Stat.Return call ]))
      in
      check (Printf.sprintf "forty levels printing %S stay a call" word)
        (Option.map (fun (f : C.Func.t) -> f.C.Func.body) folded = Some [ C.Stat.Return call ]))
    [ "w"; "" ]

(* A run that writes a member of a program variable wrote it, though the
   variable holds the same value it did, changed in place. *)
let global_member () =
  let prog = program [] in
  Hashtbl.replace prog.Eval.globals "g"
    { C.Global.symbol = "g"; linkage = C.Linkage.Local; ty = C.Ty.Struct [ C.Ty.I64; C.Ty.I64 ]; per_thread = false };
  let run = Eval.start prog in
  let c = Eval.global run "g" in
  Value.store { Value.cell = c; path = [ Value.Member 0 ]; owned = false } C.Ty.I64 (Value.VInt 1L);
  check "a member of a program variable written is a write" (Eval.wrote_globals run)

(* A call remembered for a zero is not the call for its negative, in
   either order. *)
let signed_zero () =
  let inverse =
    func "inverse" [ (1, C.Ty.F64) ]
      [ C.Stat.Return (e (C.Expr.Binary { op = C.Expr.Div; left = e (C.Expr.Float 1.) C.Ty.F64; right = e (C.Expr.Local 1) C.Ty.F64 }) C.Ty.F64) ]
  in
  let calls order =
    let prog = program [ inverse ] in
    List.map (fun x -> Eval.call (Eval.start prog) "inverse" [ Value.VFloat x ]) order
  in
  check "a zero's call, then its negative's"
    (calls [ 0.; -0. ] = [ Value.VFloat Float.infinity; Value.VFloat Float.neg_infinity ]);
  check "a negative zero's call, then the zero's"
    (calls [ -0.; 0. ] = [ Value.VFloat Float.neg_infinity; Value.VFloat Float.infinity ])

let run () =
  single_literals ();
  folded_arithmetic ();
  intrinsic_classes ();
  folded_math ();
  parsed_numbers ();
  materialized ();
  evaluated ();
  formatted_scalars ();
  stored_in_place ();
  kept_store ();
  folded_function ();
  reached_locals ();
  boxes_stored_back ();
  capped_replacement ();
  bounded_allocation ();
  replayed_outputs ();
  global_member ();
  signed_zero ()
