module Ty = Tst.Ty
module S = Tst.Signature
module T = Tst.Nodes
module Overloads = Tst__Overloads
module State = Cgt__State
module Type_layout = Cgt__Type_layout
module Value = Optimize__Value
module Eval = Optimize__Eval
module Fold = Optimize__Fold
module Materialize = Optimize__Materialize
module Intrinsics = Optimize__Intrinsics
module TIntrinsics = Tst.Intrinsics

let failures = ref 0

let check name ok =
  if not ok then begin
    incr failures;
    Printf.printf "FAIL %s\n" name
  end

let raises_bug name f =
  check name (match f () with _ -> false | exception Diagnostic.Internal _ -> true)

let span = Source.Span.of_loc (Lexing.dummy_pos, Lexing.dummy_pos)
let prim name = Ty.Intrinsic { namespace = "primitives"; name; args = [] }
let int = prim "I64"
let float = prim "F64"
let named ?(args = []) name = Ty.Named ({ Ty.package = "app"; name }, args)
let param name = Ty.fresh_param ~name ~kind:Ty.Type_kind

(* ---------------------------------------------------------------------- *)
(* Ty                                                                     *)
(* ---------------------------------------------------------------------- *)

let ty () =
  let t = param "T" and u = param "U" in
  check "equal keeps a guest apart" (not (Ty.equal (Ty.Reference int) int));
  check "assignable looks through a guest" (Ty.assignable ~dst:int ~src:(Ty.Reference int));
  check "equal tells primitives apart" (not (Ty.equal int float));
  check "Error equals anything" (Ty.equal Ty.Error (named "Point"));
  check "parameters are equal by id, not name"
    (not (Ty.equal (Ty.Param t) (Ty.Param { t with Ty.id = t.Ty.id + 1000 })));
  check "strip_mode" (Ty.strip_mode (Ty.Reference int) = int);
  check "is_ref" (Ty.is_ref (Ty.Reference int) && not (Ty.is_ref int));
  let pair = named "Pair" ~args:[ Ty.Type (Ty.Param t); Ty.Type (Ty.Param u) ] in
  check "subst replaces every parameter"
    (Ty.equal
       (Ty.subst [ (t.Ty.id, Ty.Type int); (u.Ty.id, Ty.Type float) ] pair)
       (named "Pair" ~args:[ Ty.Type int; Ty.Type float ]));
  check "subst leaves other parameters"
    (Ty.equal (Ty.subst [ (t.Ty.id, Ty.Type int) ] (Ty.Param u)) (Ty.Param u));
  check "bindings pairs parameters with arguments in order"
    (Ty.bindings [ t; u ] [ Ty.Type int; Ty.Type float ]
    = [ (t.Ty.id, Ty.Type int); (u.Ty.id, Ty.Type float) ]);
  check "instantiate"
    (Ty.equal (Ty.instantiate [ t ] [ Ty.Type int ] (Ty.Reference (Ty.Param t))) (Ty.Reference int));
  raises_bug "instantiate with too few arguments is a bug" (fun () ->
      Ty.instantiate [ t; u ] [ Ty.Type int ] (Ty.Param t));
  raises_bug "instantiate with too many arguments is a bug" (fun () ->
      Ty.instantiate [] [ Ty.Type int ] int);
  check "unify binds an open parameter"
    (Ty.unify ~open_:[ t ] [] (Ty.Param t) int = Some [ (t.Ty.id, Ty.Type int) ]);
  check "unify keeps a binding it already has"
    (Ty.unify ~open_:[ t ] [ (t.Ty.id, Ty.Type int) ] (Ty.Param t) float = None);
  check "a bare literal drives no inference"
    (Ty.unify ~open_:[ t ] [] (Ty.Param t) (Ty.Concept Ty.Integer_lit) = None);
  let fn is_mut = Ty.Verb { this_ = None; params = [ int ]; ret = int; abort = None; is_mut } in
  check "a `mut` function type holds a lambda that is not" (Ty.assignable ~dst:(fn true) ~src:(fn false));
  check "a plain function type does not hold a `mut` one" (not (Ty.assignable ~dst:(fn false) ~src:(fn true)))

(* ---------------------------------------------------------------------- *)
(* Signature                                                              *)
(* ---------------------------------------------------------------------- *)

let signature ?(kind = S.Function) ?(generics = []) name params ret =
  {
    S.owner = S.Intrinsic name;
    name;
    home = S.Package "app";
    kind;
    generics;
    params =
      List.map (fun (name, ty) -> { S.name; ty; binds = None; has_default = false }) params;
    ret;
    abort = None;
    is_mut = false;
  }

let signatures () =
  let f = signature "f" [ ("x", int) ] float in
  check "a function prints as it is declared"
    (S.to_string f = "@primitives$F64 f(@primitives$I64)");
  let m = signature ~kind:S.Method "size" [ ("this", named "Bag"); ("n", int) ] int in
  check "a method prints its subject" (S.to_string m = "@primitives$I64 size(this app$Bag, @primitives$I64)");
  check "is_method" (S.is_method m && not (S.is_method f));
  check "has_block_param" (S.has_block_param (signature "g" [ ("b", Ty.Concept Ty.Block) ] int))

(* ---------------------------------------------------------------------- *)
(* Overload ranking                                                       *)
(* ---------------------------------------------------------------------- *)

let actual ty =
  {
    Overloads.arg = T.Arg.Value { T.Expr.node = T.Expr.Invalid; ty; span };
    aty = ty;
    aspan = span;
    subject = false;
  }

let resolve candidates args =
  Overloads.resolve (Tst__Env.create ()) candidates (fun s -> Overloads.positional (List.map actual args) s)

let name_of = function
  | Overloads.Resolved o -> o.Overloads.sig_.S.name
  | Overloads.No_match -> "no match"
  | Overloads.Ambiguous _ -> "ambiguous"

let overloads () =
  let t = param "T" in
  let on_int = signature "onInt" [ ("x", int) ] int
  and on_float = signature "onFloat" [ ("x", float) ] int
  and generic = signature ~generics:[ t ] "generic" [ ("x", Ty.Param t) ] int
  and twice = signature "twice" [ ("x", int); ("y", int) ] int in
  check "the candidate whose parameter matches" (name_of (resolve [ on_int; on_float ] [ float ]) = "onFloat");
  check "an exact candidate before a generic one" (name_of (resolve [ generic; on_int ] [ int ]) = "onInt");
  check "a generic candidate when no exact one matches"
    (match resolve [ generic; on_int ] [ float ] with
    | Overloads.Resolved o -> o.Overloads.sig_.S.name = "generic" && o.Overloads.subst = [ (t.Ty.id, Ty.Type float) ]
    | _ -> false);
  check "two exact candidates are ambiguous"
    (name_of (resolve [ on_int; { on_int with S.name = "again" } ] [ int ]) = "ambiguous");
  check "the wrong number of arguments matches nothing" (name_of (resolve [ twice ] [ int ]) = "no match");
  check "all_some" (Overloads.all_some [ Some 1; Some 2 ] = Some [ 1; 2 ]);
  check "all_some with one missing" (Overloads.all_some [ Some 1; None ] = None)

let string_constructors () =
  let params =
    List.filter_map
      (fun ((namespace, name), (signature : S.t)) ->
        if namespace = "primitives" && name = "String" then
          match signature.S.params with [ p ] -> Some p.S.ty | _ -> None
        else None)
      TIntrinsics.constructors
  in
  List.iter
    (fun (name, scalar) ->
      check
        ("String has a constructor from " ^ name)
        (List.exists (Ty.equal scalar) params))
    [ ("I32", prim "I32"); ("I64", prim "I64"); ("F32", prim "F32"); ("F64", prim "F64") ]

(* ---------------------------------------------------------------------- *)
(* Type layout                                                            *)
(* ---------------------------------------------------------------------- *)

let type_layout () =
  let st = State.create ~region:Cgt.Runtime.default_fixed_region ~import_bodies:false ~library:false ~exclusive:false ~exports:(fun _ -> false) ~stamp:(fun _ -> "") ~stamped:(fun _ -> false) in
  let t = param "T" in
  Hashtbl.replace st.State.types ("app", "Box")
    ([ t ], T.Decl.Struct [ ("item", Ty.Param t); ("count", int) ], false);
  let box = named "Box" ~args:[ Ty.Type float ] in
  let array =
    Ty.Intrinsic { namespace = "primitives"; name = "Array"; args = [ Ty.Type int; Ty.Number (Ty.Known 3) ] }
  in
  let module N = Cgt.Nodes.Ty in
  check "Int is an i64" (Type_layout.ty st span int = N.I64);
  check "Float is an f64" (Type_layout.ty st span float = N.F64);
  check "Unit is void" (Type_layout.ty st span (prim "Unit") = N.Void);
  check "an array is an LLVM array" (Type_layout.ty st span array = N.Array (N.I64, 3));
  check "array_of" (Type_layout.array_of array = Some (int, 3));
  check "a struct's members are instantiated"
    (match Type_layout.definition st box with
    | Some (T.Decl.Struct [ ("item", item); ("count", _) ], false) -> Ty.equal item float
    | _ -> false);
  check "a struct is a struct of its members" (Type_layout.ty st span box = N.Struct [ N.F64; N.I64 ]);
  check "a value type is not a reference" (not (Type_layout.reference st box));
  raises_bug "a declared type with the wrong number of arguments is a bug" (fun () ->
      Type_layout.definition st (named "Box"))

(* ---------------------------------------------------------------------- *)
(* The runtime's ABI                                                      *)
(* ---------------------------------------------------------------------- *)

(* runtime/zane.h without its comments and preprocessor lines. *)
let header () =
  let text = In_channel.with_open_text "../../runtime/zane.h" In_channel.input_all in
  let b = Buffer.create (String.length text) in
  let n = String.length text in
  let rec go i =
    if i >= n then ()
    else if i + 1 < n && text.[i] = '/' && text.[i + 1] = '*' then
      let rec close j = if j + 1 >= n || (text.[j] = '*' && text.[j + 1] = '/') then j + 2 else close (j + 1) in
      go (close (i + 2))
    else if text.[i] = '#' && (i = 0 || text.[i - 1] = '\n') then
      go (match String.index_from_opt text i '\n' with Some j -> j | None -> n)
    else begin
      Buffer.add_char b text.[i];
      go (i + 1)
    end
  in
  go 0;
  Buffer.contents b

(* Each prototype the header declares: its name, the C type it returns and
   the C types of its parameters, by the text that spells them. *)
let prototypes () =
  let declarations = String.split_on_char ';' (header ()) in
  List.filter_map
    (fun d ->
      let d = String.trim (String.map (function '\n' | '\t' -> ' ' | c -> c) d) in
      match String.index_opt d '(' with
      | None -> None
      | Some open_ ->
          let before = String.trim (String.sub d 0 open_) in
          let cut = match String.rindex_opt before ' ' with Some i -> i + 1 | None -> 0 in
          let cut = match String.rindex_opt before '*' with Some i when i + 1 > cut -> i + 1 | _ -> cut in
          let name = String.sub before cut (String.length before - cut) in
          if not (String.starts_with ~prefix:"zane_" name) then None
          else
            let ret = String.trim (String.sub before 0 cut) in
            (* The parameters: up to the parenthesis that closes the list,
               split at the commas outside a function pointer's own. *)
            let params = Buffer.create 64 and parts = ref [] and depth = ref 0 in
            String.iteri
              (fun i c ->
                if i > open_ then
                  match c with
                  | '(' -> incr depth; Buffer.add_char params c
                  | ')' when !depth = 0 -> depth := -1
                  | ')' -> decr depth; Buffer.add_char params c
                  | ',' when !depth = 0 ->
                      parts := Buffer.contents params :: !parts;
                      Buffer.clear params
                  | c -> if !depth >= 0 then Buffer.add_char params c)
              d;
            parts := Buffer.contents params :: !parts;
            let params = List.rev_map String.trim !parts in
            let params = match params with [ "void" ] | [ "" ] -> [] | ps -> ps in
            Some (name, ret, params))
    declarations

(* How the C ABI passes a type the header spells. *)
let abi c =
  let module R = Cgt.Runtime in
  if String.contains c '*' then Some R.Ptr
  else
    let words = List.filter (fun w -> w <> "" && w <> "const") (String.split_on_char ' ' c) in
    match words with
    | [ "void" ] -> Some R.Void
    | ("int64_t" :: _) -> Some R.I64
    | (("uint32_t" | "int32_t") :: _) -> Some R.I32
    | ("float" :: _) -> Some R.F32
    | ("double" :: _) -> Some R.F64
    | _ -> None

let runtime_abi () =
  let module R = Cgt.Runtime in
  let declared = prototypes () in
  check "the header declares functions" (List.length declared > 20);
  List.iter
    (fun fn ->
      let name = R.name fn in
      match List.find_opt (fun (n, _, _) -> n = name) declared with
      | None -> check (name ^ " is declared in zane.h") false
      | Some (_, ret, params) ->
          let ret', params' = R.signature fn in
          check (name ^ " returns what zane.h says") (abi ret = Some ret');
          check
            (name ^ " takes what zane.h says")
            (List.length params = List.length params'
            && List.for_all2 (fun c t -> abi c = Some t) params params'))
    R.all;
  (* `zane_main` is the one function the program defines rather than calls. *)
  List.iter
    (fun (name, _, _) ->
      check (name ^ " in zane.h is a function the compiler knows")
        (name = "zane_main" || List.exists (fun fn -> R.name fn = name) R.all))
    declared

(* ---------------------------------------------------------------------- *)
(* Stage 5                                                                *)
(* ---------------------------------------------------------------------- *)

module C = Cgt.Nodes

let stops f = match f () with _ -> false | exception Value.Stop _ -> true

(* The evaluator's arithmetic is codegen's (lib/codegen/emit.ml). *)
(* An F32 literal rounds once, from the decimal straight to the single
   (Tst.Decimal): where the double nearest the literal is the midpoint of two
   singles, the literal's own side of it decides. *)
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
   input. *)
let intrinsic_classes () =
  let outputs =
    List.filter (fun fn -> Intrinsics.classify fn = Intrinsics.Output) Cgt.Runtime.all
  in
  check "print and the thread count are the outputs"
    (List.sort compare outputs
    = List.sort compare Cgt.Runtime.[ Print; Set_threads; Set_threads_auto ]);
  check "the program's arguments are the one input"
    (List.filter (fun fn -> Intrinsics.classify fn = Intrinsics.Input) Cgt.Runtime.all
    = Cgt.Runtime.[ Arguments ])

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

let e node ty = { C.Expr.node; ty }
let i64 n = e (C.Expr.Int n) C.Ty.I64

let program funcs =
  let funcs' = Hashtbl.create 8 in
  List.iter (fun (f : C.Func.t) -> Hashtbl.replace funcs' f.C.Func.symbol f) funcs;
  {
    Eval.funcs = funcs';
    layouts = Hashtbl.create 1;
    globals = Hashtbl.create 1;
    constants = Hashtbl.create 1;
    memo = Value.Key.create 8;
    left = Eval.total;
  }

let func symbol params body = { C.Func.symbol; linkage = C.Linkage.Local; params; ret = C.Ty.I64; body }

(* A value made back into code, and read back, is the value it was. *)
let materialized () =
  let t = C.Ty.Sum [ C.Ty.Struct [ C.Ty.I64; C.Ty.Handle ]; C.Ty.Void ] in
  let c = Value.Case (0, Value.Record [| Value.Int 3L; Value.Text "hi" |]) in
  check "a variant of a struct is code and back"
    (Option.bind (Materialize.expr t c) Materialize.const = Some c);
  check "a string is no function's address" (Materialize.expr C.Ty.Ptr (Value.Text "x") = None)

(* Calls run, outputs are kept in order, a call made again is remembered,
   and a budget spent or a constant made where it is read stops the run. *)
let evaluated () =
  let print s = C.Stat.Eval (e (C.Expr.Runtime { fn = Cgt.Runtime.Print; args = [ e (C.Expr.Text s) C.Ty.Handle ] }) C.Ty.Void) in
  let double =
    func "double" [ (1, C.Ty.I64) ]
      [ print "a"; print "b"; C.Stat.Return (e (C.Expr.Binary { op = C.Expr.Mul; left = e (C.Expr.Local 1) C.Ty.I64; right = i64 2L }) C.Ty.I64) ]
  in
  let prog = program [ double ] in
  let run = Eval.start prog in
  check "a call gives its result" (Eval.call run "double" [ Value.VInt 21L ] = Value.VInt 42L);
  check "outputs are kept in the order made" (List.rev run.Eval.outputs = Eval.[ Print "a"; Print "b" ]);
  check "a call is remembered by its arguments" (Value.Key.mem prog.Eval.memo ("double", [ Value.Int 21L ]));
  let again = Eval.start prog in
  ignore (Eval.call again "double" [ Value.VInt 21L ]);
  check "a remembered call outputs again" (List.rev again.Eval.outputs = Eval.[ Print "a"; Print "b" ]);
  let forever = C.Stat.Repeat { count = i64 Int64.max_int; body = [] } in
  let fr = { Eval.locals = Hashtbl.create 1; outer = None } in
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

(* A run that writes a member of a program variable wrote it, though the
   variable holds the same value it did, changed in place. *)
let global_member () =
  let prog = program [] in
  Hashtbl.replace prog.Eval.globals "g"
    { C.Global.symbol = "g"; linkage = C.Linkage.Local; ty = C.Ty.Struct [ C.Ty.I64; C.Ty.I64 ] };
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

(* ---------------------------------------------------------------------- *)
(* Semantics twice                                                        *)
(* ---------------------------------------------------------------------- *)

(* The fixture's typed tree, when it assembles and checks cleanly. *)
let tree () =
  match Tst.Assembly.assemble [ "../codegen/fixtures/lambdas" ] with
  | Error _ -> None
  | Ok packages -> (
      match Tst.check packages with
      | { Tst.Semantics.diagnostics = []; program } ->
          Some (Tree_graph.render (Tst.to_node ~bodies:true program))
      | _ -> None)

let twice () =
  match (tree (), tree ()) with
  | Some first, Some second ->
      check "semantics run twice gives the same tree" (String.equal first second)
  | _ -> check "the fixture checked twice assembles and checks cleanly" false

(* Each check has tables of its own, so two can run at once and give what
   one gives alone. *)
let at_once () =
  let a = Domain.spawn tree and b = Domain.spawn tree in
  match (tree (), Domain.join a, Domain.join b) with
  | Some alone, Some first, Some second ->
      check "two checks at once give what one gives alone"
        (String.equal alone first && String.equal alone second)
  | _ -> check "the fixture checked at once assembles and checks cleanly" false

(* A snapshot of an 8-byte value aligned to 8 is a single load: acquire when
   it holds an address, so what the address names is seen with it, and
   unordered otherwise. Anything narrower, wider, or aligned below its size,
   is read by the runtime. *)
let snapshot_reads () =
  let module T = Cgt.Nodes.Ty in
  let read = Codegen__Emit.snapshot_read in
  check "an I64 is one unordered load" (read T.I64 = `Unordered);
  check "an F64 is one unordered load" (read T.F64 = `Unordered);
  check "a Bool is read by the runtime" (read T.I1 = `Runtime);
  check "an I32 is read by the runtime" (read T.I32 = `Runtime);
  check "an F32 is read by the runtime" (read T.F32 = `Runtime);
  check "an address is one acquire load" (read T.Ptr = `Acquire);
  check "a struct holding only a box is one acquire load" (read (T.Struct [ T.Ptr ]) = `Acquire);
  check "two I32s, aligned below their size, are read by the runtime"
    (read (T.Struct [ T.I32; T.I32 ]) = `Runtime);
  check "a handle is read by the runtime" (read T.Handle = `Runtime);
  check "two I64s are read by the runtime" (read (T.Struct [ T.I64; T.I64 ]) = `Runtime)

(* Code for x86-64 is tuned as clang tunes it, for the baseline `x86-64`
   processor whatever spelling the triple has, and for Haswell on `x86_64h`;
   other targets keep LLVM's default. *)
let target_cpus () =
  let cpu target = Codegen.target_cpu ~target () in
  check "an x86-64 Linux target is tuned for x86-64" (cpu "x86_64-unknown-linux-gnu" = Ok "x86-64");
  check "a short x86-64 Windows triple is tuned for x86-64" (cpu "x86_64-windows-gnu" = Ok "x86-64");
  check "an amd64 triple is tuned for x86-64" (cpu "amd64-unknown-freebsd" = Ok "x86-64");
  check "an x86_64h target is tuned for Haswell" (cpu "x86_64h-apple-darwin" = Ok "core-avx2");
  check "an AArch64 target keeps LLVM's default" (cpu "aarch64-unknown-linux-gnu" = Ok "")

(* A type's size is built with checked arithmetic, and one of 2^48 bytes or
   more is refused rather than wrapping (docs/design/lowering.md §9). *)
let checked_sizes () =
  let module T = Cgt.Nodes.Ty in
  let refused t = match T.size_align t with _ -> false | exception T.Too_large -> true in
  check "2^32 I64s take 32 GiB" (T.size_align (T.Array (T.I64, 1 lsl 32)) = (1 lsl 35, 8));
  check "an array of arrays multiplies both lengths"
    (T.size_align (T.Array (T.Array (T.I64, 65536), 65536)) = (1 lsl 35, 8));
  check "just under 2^48 bytes is a size" (T.size_align (T.Array (T.I64, (1 lsl 45) - 1)) = ((1 lsl 48) - 8, 8));
  check "2^48 bytes is refused" (refused (T.Array (T.I64, 1 lsl 45)));
  check "2^60 I64s, which wrap to 0 unchecked, are refused" (refused (T.Array (T.I64, 1 lsl 60)));
  check "a length past max_int / 8 is refused" (refused (T.Array (T.I64, max_int)));
  check "two members that together reach the limit are refused"
    (refused (T.Struct [ T.Array (T.I64, 1 lsl 44); T.Array (T.I64, 1 lsl 44) ]));
  check "a sum whose payload reaches the limit is refused" (refused (T.Sum [ T.Array (T.I64, 1 lsl 45) ]));
  check "nothing many times over takes nothing" (T.size_align (T.Array (T.Void, max_int)) = (0, 1))

(* An LLVM array type keeps all 64 bits of its length, which the bindings'
   own `array_type` truncates to 32 (llvm_stubs.c). *)
let long_arrays () =
  let ctx = Llvm.create_context () in
  let m = Llvm.create_module ctx "unit" in
  let ptr = Llvm.pointer_type ctx and i64 = Llvm.i64_type ctx in
  let tags = Codegen__Emit.tags ctx in
  let env =
    {
      Codegen__Emit.ctx;
      m;
      ptr;
      i64;
      funcs = Hashtbl.create 1;
      globals = Hashtbl.create 1;
      walks = None;
      handle_tag = fst tags;
      value_tag = snd tags;
    }
  in
  let t = Codegen__Emit.lltype env (Cgt.Nodes.Ty.Array (Cgt.Nodes.Ty.I1, 4294967297)) in
  check "an array of 2^32 + 1 elements keeps its length" (Codegen__Emit.array_length t = 4294967297);
  check "its parts saturate past LLVM's limit"
    (Codegen__Big_moves.parts t = Codegen__Big_moves.most_parts + 1);
  check "a sum's payload room keeps its length"
    (Codegen__Emit.array_length
       (Llvm.struct_element_types
          (Codegen__Emit.lltype env (Cgt.Nodes.Ty.Sum [ Cgt.Nodes.Ty.Array (Cgt.Nodes.Ty.I64, 1 lsl 33) ]))).(1)
    = 1 lsl 33);
  Llvm.dispose_module m;
  Llvm.dispose_context ctx

(* A target is refused unless its pointers are 8 bytes and it aligns `i64`
   and `double` to 8 (docs/design/platforms.md). No 64-bit LLVM target
   aligns either below that, so the layouts are written out here. *)
let sixty_four_bit () =
  let accepts layout =
    Codegen__Build.sixty_four_bit "t" (Llvm_target.DataLayout.of_string layout)
  in
  check "8-byte pointers with i64 and double aligned to 8 are accepted"
    (accepts "e-m:e-p:64:64-i64:64-f64:64" = Ok ());
  check "4-byte pointers are refused"
    (accepts "e-p:32:32-i64:64-f64:64"
    = Error "the target `t` has 4-byte pointers; this compiler builds for 64-bit targets only");
  check "an i64 aligned to 4 is refused"
    (accepts "e-p:64:64-i64:32-f64:64"
    = Error "the target `t` aligns `i64` to 4 bytes; this compiler builds for 64-bit targets only");
  check "a double aligned to 4 is refused"
    (accepts "e-p:64:64-i64:64-f64:32"
    = Error "the target `t` aligns `double` to 4 bytes; this compiler builds for 64-bit targets only")

(* ---------------------------------------------------------------------- *)
(* The driver                                                             *)
(* ---------------------------------------------------------------------- *)

(* What a file holds, or [None] when it is gone. *)
let read_all path =
  try Some (In_channel.with_open_bin path In_channel.input_all) with Sys_error _ -> None
let write_all path contents = Out_channel.with_open_bin path (fun oc -> output_string oc contents)

let rec remove_tree path =
  if Sys.is_directory path then begin
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Sys.rmdir path
  end
  else Sys.remove path

(* Rewriting writes beside its output under a name it creates exclusively.
   A name that is already there is someone else's file: it is kept, and the
   object goes out under the next name drawn. *)
let rewriting_keeps_others_files () =
  let seed = [| 17 |] in
  let names output count =
    let random = Random.State.make seed in
    List.init count (fun _ -> Driver.temporary_name random output)
  in
  let rewrite contents = Ok (contents ^ " rewritten", 0) in
  let in_directory f =
    let directory = Filename.temp_dir "zane-rewrite" "" in
    Fun.protect ~finally:(fun () -> remove_tree directory) (fun () -> f directory)
  in
  in_directory (fun directory ->
      let input = Filename.concat directory "in.o" and output = Filename.concat directory "out.o" in
      write_all input "object";
      let first, second =
        match names output 2 with [ first; second ] -> (first, second) | _ -> assert false
      in
      write_all first "someone else's";
      let random = Random.State.make seed in
      let result = Driver.rewrite_object ~random ~stamps:[] ~rewrite ~input ~output in
      check "a rewrite whose first name is taken succeeds" (Result.is_ok result);
      check "the file at the taken name survives" (read_all first = Some "someone else's");
      check "the output is written" (read_all output = Some "object rewritten");
      check "the output went out under the next name, renamed away" (not (Sys.file_exists second));
      check "exactly two names were drawn"
        (Random.State.bits random
        = Random.State.bits
            (let r = Random.State.make seed in
             ignore (Random.State.bits r);
             ignore (Random.State.bits r);
             r)));
  in_directory (fun directory ->
      let input = Filename.concat directory "in.o" and output = Filename.concat directory "out.o" in
      write_all input "object";
      let first = List.hd (names output 1) in
      (* A symlink needs a privilege on Windows; without one there is nothing
         to test. *)
      match Unix.symlink (Filename.concat directory "nowhere") first with
      | exception Unix.Unix_error _ -> ()
      | () ->
          let result =
            Driver.rewrite_object ~random:(Random.State.make seed) ~stamps:[] ~rewrite ~input ~output
          in
          check "a rewrite whose first name is a dangling symlink succeeds" (Result.is_ok result);
          check "the dangling symlink survives"
            (match Unix.readlink first with _ -> true | exception Unix.Unix_error _ -> false);
          check "the output is written past the symlink" (read_all output = Some "object rewritten");
          Sys.remove first);
  in_directory (fun directory ->
      let input = Filename.concat directory "in.o" and output = Filename.concat directory "out.o" in
      write_all input "object";
      let taken = names output 8 in
      List.iteri (fun i name -> write_all name (string_of_int i)) taken;
      let result =
        Driver.rewrite_object ~random:(Random.State.make seed) ~stamps:[] ~rewrite ~input ~output
      in
      check "a rewrite whose eight names are all taken fails" (Result.is_error result);
      check "every taken name survives"
        (List.for_all Fun.id (List.mapi (fun i name -> read_all name = Some (string_of_int i)) taken));
      check "no output is written" (not (Sys.file_exists output)))

let contains text part =
  let n = String.length part in
  let rec go i = i + n <= String.length text && (String.sub text i n = part || go (i + 1)) in
  go 0

(* A stamp given by package name is checked as `--rewrite`'s is, so a caller
   that is not `zanec` cannot name a package's symbols with something
   lowering would not read as a stamp. *)
let stamps_are_checked () =
  let request = { Tst.Assembly.manifest_name = Some "geometry"; directory = "nowhere"; stamp = None } in
  match Driver.assemble ~root:false ~stamps:[ ("geometry", "garbage") ] [ request ] with
  | Ok _ -> check "a malformed stamp is refused" false
  | Error failure ->
      check "a malformed stamp is named as no stamp"
        (List.exists (fun line -> contains line "`garbage` is not a stamp") (Driver.render failure))

(* tests/gen/gen_rules.ml stops at a fixture with no golden file and at a
   golden file whose fixture is gone, naming each, so neither leaves a
   program silently untested. *)
let fixture_pairing () =
  let module P = Fixture_pairing in
  let check_pairs ?hand_written name suite ~fixtures ~goldens expected =
    let errors = P.check ?hand_written suite ~fixtures ~goldens in
    check name (errors = expected);
    if errors <> expected then List.iter (Printf.printf "  got: %s\n") errors
  in
  check_pairs "paired codegen fixtures pass" P.Codegen
    ~fixtures:[ "fixtures/hello"; "fixtures/reject/flow" ]
    ~goldens:[ "hello.cgt"; "hello.optimized.cgt"; "hello.out"; "reject.flow.err" ]
    [];
  check_pairs "an orphan fixture and an orphan golden are both named" P.Codegen
    ~fixtures:[ "fixtures/hello"; "fixtures/untested" ]
    ~goldens:[ "hello.out"; "gone.out" ]
    [ "golden/gone.out is for fixtures/gone, which does not exist"; "fixtures/untested has no golden file" ];
  check_pairs "a golden file no rule makes is named" P.Codegen ~fixtures:[ "fixtures/hello" ]
    ~goldens:[ "hello.out"; "hello.txt" ]
    [ "no rule makes golden/hello.txt" ];
  check_pairs "a parser rejection pairs with its source" P.Parser
    ~fixtures:[ "fixtures/main.zn"; "fixtures/reject/lexing.zn"; "fixtures/reject/lost.zn" ]
    ~goldens:[ "main.cst.spans"; "reject.lexing.err"; "reject.syntax.err" ]
    [
      "golden/reject.syntax.err is for fixtures/reject/syntax.zn, which does not exist";
      "fixtures/reject/lost.zn has no golden file";
    ];
  check_pairs "a runtime test pairs with its output" P.Runtime ~fixtures:[ "arenas.c"; "texts.c" ]
    ~goldens:[ "arenas.out" ] [ "texts.c has no golden file" ];
  check_pairs "hand-written semantics rules are left alone" P.Semantics
    ~hand_written:[ "assembly.accept.packages"; "project.app.check" ]
    ~fixtures:[ "fixtures/typing/accept" ]
    ~goldens:[ "assembly.accept.packages"; "project.app.check"; "typing.accept.tst.spans" ]
    [];
  check_pairs "a golden file no hand-written rule compares against is named" P.Semantics
    ~hand_written:[ "project.app.check" ]
    ~fixtures:[] ~goldens:[ "project.app.check"; "project.app.chek" ]
    [ "no rule makes golden/project.app.chek" ]

let () =
  ty ();
  signatures ();
  overloads ();
  string_constructors ();
  type_layout ();
  runtime_abi ();
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
  capped_replacement ();
  bounded_allocation ();
  global_member ();
  signed_zero ();
  twice ();
  at_once ();
  snapshot_reads ();
  target_cpus ();
  sixty_four_bit ();
  checked_sizes ();
  long_arrays ();
  fixture_pairing ();
  rewriting_keeps_others_files ();
  stamps_are_checked ();
  if !failures > 0 then begin
    Printf.printf "%d failed\n" !failures;
    exit 1
  end
