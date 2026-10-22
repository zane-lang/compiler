module Ty = Tst.Ty
module S = Tst.Signature
module T = Tst.Nodes
module Overloads = Tst__Overloads
module Borrows = Tst__Borrows
module Fixpoint = Tst__Fixpoint
module Abi = Codegen__Abi
module State = Cgt__State
module Type_layout = Cgt__Type_layout
module Value = Optimize__Value
module Eval = Optimize__Eval
module Fold = Optimize__Fold
module Materialize = Optimize__Materialize
module Intrinsics = Optimize__Intrinsics
module TIntrinsics = Tst.Intrinsics

open Support

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
      Type_layout.definition st (named "Box"));
  (* An array of owning elements is one position, which names its
     element's layout, however long it is. *)
  let strings n =
    Ty.Intrinsic { namespace = "primitives"; name = "Array"; args = [ Ty.Type (prim "String"); Ty.Number (Ty.Known n) ] }
  in
  let module L = Cgt.Nodes.Layout in
  check "an array of 100,000 strings is one position"
    (match Type_layout.positions st span (strings 100_000) 0 [] with
    | [ { L.kind = L.Array { count = 100_000; stride = 24; elements }; offset = 0; _ } ] ->
        (match Hashtbl.find st.State.layouts elements with
        | [ { L.kind = L.Text; offset = 0; tags = []; _ } ] -> true
        | _ -> false)
    | _ -> false);
  check "an array of arrays of strings is one position"
    (match Type_layout.positions st span (Ty.Intrinsic { namespace = "primitives"; name = "Array"; args = [ Ty.Type (strings 10); Ty.Number (Ty.Known 1000) ] }) 0 [] with
    | [ { L.kind = L.Array { count = 1000; stride = 240; elements }; _ } ] -> (
        match Hashtbl.find st.State.layouts elements with
        | [ { L.kind = L.Array { count = 10; stride = 24; _ }; _ } ] -> true
        | _ -> false)
    | _ -> false);
  check "an array of what owns nothing has no positions" (Type_layout.positions st span array 0 [] = [])

(* A type that holds itself at a growing argument (generics.md §2.4), which
   semantics rejects, reaches lowering only by a bug; the walks over its
   members then stop at their depth limit instead of running forever. *)
let growing_types () =
  let st = State.create ~region:Cgt.Runtime.default_fixed_region ~import_bodies:false ~library:false ~exclusive:false ~exports:(fun _ -> false) ~stamp:(fun _ -> "") ~stamped:(fun _ -> false) in
  let t = param "T" in
  let pair e = Ty.Intrinsic { namespace = "primitives"; name = "Array"; args = [ Ty.Type e; Ty.Number (Ty.Known 2) ] } in
  Hashtbl.replace st.State.types ("app", "Grow")
    ([ t ], T.Decl.Variant [ ("done", prim "Unit"); ("more", named "Grow" ~args:[ Ty.Type (pair (Ty.Param t)) ]) ], false);
  let grow = named "Grow" ~args:[ Ty.Type int ] in
  let more = named "Grow" ~args:[ Ty.Type (pair int) ] in
  raises_bug "boxing a growing type stops once it keeps growing" (fun () -> Type_layout.boxed st grow more);
  raises_bug "laying out a growing type stops once it keeps growing" (fun () -> Type_layout.layout st span grow);
  let deeper = function
    | Ty.Named (_, [ Ty.Type e ]) -> [ Ty.Reference (named "Node" ~args:[ Ty.Type (pair e) ]) ]
    | _ -> []
  in
  raises_bug "following references through a growing type stops once it keeps growing" (fun () ->
      Borrows.reached_through_references ~members:deeper (named "Node" ~args:[ Ty.Type int ]))

(* A chain of 2,000 verbs, each calling the next, listed caller first, so
   that the fact the last one starts gets back to the first one link by link.
   Walking every body until no summary grows takes a round per link, so about
   n * n walks; the worklist walks each body once and each caller once more
   (Fixpoint, F25). The round-robin count is taken here too, so the chain is
   known to be the worst case for it. *)
let fixpoint_chain () =
  let n = 2000 in
  let walk t i =
    Fixpoint.add t i (if i = n - 1 then true else Fixpoint.read t (i + 1))
  in
  let t = Fixpoint.create ~empty:false ~union:( || ) ~equal:Bool.equal in
  let reported = ref 0 in
  Fixpoint.settle t (List.init n Fun.id) (fun ~report i ->
      if report then incr reported;
      walk t i);
  check "the fixed point reaches the head of the chain" (Fixpoint.read t 0);
  check "every body is walked once more to report" (!reported = n);
  check "a worst-first chain settles in a walk per body and one per caller"
    (Fixpoint.walks t = (2 * n) - 1);
  let rounds = Fixpoint.create ~empty:false ~union:( || ) ~equal:Bool.equal in
  let walks = ref 0 and changed = ref true in
  while !changed do
    changed := false;
    for i = 0 to n - 1 do
      incr walks;
      let before = Fixpoint.read rounds i in
      walk rounds i;
      if Fixpoint.read rounds i <> before then changed := true
    done
  done;
  check "walking every body until nothing grows is quadratic on the chain" (!walks = n * (n + 1))

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

(* What the runtime's structs measure, as tests/runtime/abi/probe.c prints
   it on this platform, against the numbers the compiler emits code with,
   which Abi reads from runtime/zane_abi.h. Every number is measured but the
   two nothing but the header defines. *)
let probed_abi () =
  let probed =
    In_channel.with_open_text "../runtime/abi/probe.out" In_channel.input_lines
    |> List.filter_map (fun line ->
           match String.split_on_char ' ' line with
           | [ name; value ] -> Some (name, int_of_string value)
           | _ -> None)
  in
  check "the probe measures something" (probed <> []);
  List.iter
    (fun (name, value) ->
      check
        (Printf.sprintf "%s is %d in the runtime and in Abi" name value)
        (List.assoc_opt name Abi.values = Some value))
    probed;
  check "every number in Abi is measured but ZANE_LINE and ZANE_GUARD"
    (List.sort compare
       (List.filter (fun (name, _) -> not (List.mem_assoc name probed)) Abi.values |> List.map fst)
    = [ "ZANE_GUARD"; "ZANE_LINE" ]);
  check "lowering lays a handle out as the runtime does"
    (Cgt.Nodes.Ty.size_align Cgt.Nodes.Ty.Handle = (Abi.handle_size, 8))

(* Many programs built in one process, each with functions that take no
   parameters and one that returns an empty struct: LLVM's bindings give an
   empty array as a block of no size in the minor heap, which corrupts it,
   so codegen reads those arrays through stubs of its own (llvm_stubs.c). *)
let repeated_builds () =
  let module C = Cgt.Nodes in
  let f i =
    { C.Func.symbol = "f" ^ string_of_int i; linkage = C.Linkage.Exported; params = []; ret = C.Ty.I64;
      body = [ C.Stat.Return { C.Expr.node = C.Expr.Int 1L; ty = C.Ty.I64 } ] }
  in
  let empty =
    { C.Func.symbol = "empty"; linkage = C.Linkage.Exported; params = []; ret = C.Ty.Struct [];
      body = [ C.Stat.Return { C.Expr.node = C.Expr.Record []; ty = C.Ty.Struct [] } ] }
  in
  let p = { C.Program.funcs = empty :: List.init 2000 f; entry = None; layouts = []; globals = [] } in
  let built = ref 0 in
  for _ = 1 to 60 do
    match Driver.ir ~optimize:false p with Ok _ -> incr built | Error _ -> ()
  done;
  check "sixty builds of zero-parameter functions in one process" (!built = 60)

(* A build's LLVM context and module are disposed however it ends: built,
   refused before codegen starts (an unknown target), failed after (an
   object it cannot write), or raised out of. *)
let disposed_modules () =
  let module C = Cgt.Nodes in
  let f =
    { C.Func.symbol = "f"; linkage = C.Linkage.Exported; params = []; ret = C.Ty.I64;
      body = [ C.Stat.Return { C.Expr.node = C.Expr.Int 1L; ty = C.Ty.I64 } ] }
  in
  let p = { C.Program.funcs = [ f ]; entry = None; layouts = []; globals = [] } in
  let dir = Filename.temp_dir "zane-unit" "" in
  let none () = Codegen.live_contexts () = 0 in
  check "a built object leaves no context"
    (Result.is_ok (Driver.object_file ~optimize:false p (Filename.concat dir "f.o")) && none ());
  check "an unknown target leaves no context"
    (Result.is_error (Driver.object_file ~target:"nowhere-at-all" ~optimize:false p (Filename.concat dir "g.o")) && none ());
  check "an object that cannot be written leaves no context"
    (Result.is_error (Driver.object_file ~optimize:false p (Filename.concat dir "missing/f.o")) && none ());
  let inside = ref 0 in
  (match Codegen.with_program p (fun _ -> inside := Codegen.live_contexts (); failwith "raised") with
  | _ -> ()
  | exception Failure _ -> ());
  check "a build that raises leaves no context, and had one while it ran" (!inside = 1 && none ());
  Sys.remove (Filename.concat dir "f.o");
  Sys.rmdir dir

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
  {
    Eval.funcs = Eval.functions funcs;
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

(* Layouts share their walks when their positions are alike and what each
   nests is walked alike: two lists of strings under different names, and
   two boxed lists that name themselves, share; a list of a differently
   laid-out record, or a box of a different size, does not. *)
let shared_walks () =
  let module L = Cgt.Nodes.Layout in
  let at kind = { L.kind; offset = 0; size = 24; tags = [] } in
  let positions = Hashtbl.create 8 in
  List.iter
    (fun (l, ps) -> Hashtbl.replace positions l ps)
    [
      ("Strings", [ at L.Text ]);
      ("Names", [ at L.Text ]);
      ("Pair", [ at L.Text; { (at L.Text) with L.offset = 24 } ]);
      ("A", [ at (L.List { stride = 24; elements = "Strings" }) ]);
      ("B", [ at (L.List { stride = 24; elements = "Names" }) ]);
      ("C", [ at (L.List { stride = 24; elements = "Pair" }) ]);
      ("Node", [ at (L.Box { size = 8; payload = "Node" }) ]);
      ("Link", [ at (L.Box { size = 8; payload = "Link" }) ]);
      ("Wide", [ at (L.Box { size = 16; payload = "Wide" }) ]);
    ];
  let alike = Codegen__Walks.alike positions in
  let shares a b = Hashtbl.find alike a = Hashtbl.find alike b in
  check "two layouts of one string share their walks" (shares "Strings" "Names");
  check "so do lists of them under different names" (shares "A" "B");
  check "a list of another layout has its own" (not (shares "A" "C"));
  check "two boxes that name themselves share theirs" (shares "Node" "Link");
  check "a box of another size has its own" (not (shares "Node" "Wide"));
  check "a shared walk is named for the first layout"
    (Hashtbl.find alike "Names" = "Names" && Hashtbl.find alike "Strings" = "Names")

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
(* What Emit builds a module with, for [triple] and with or without
   packing, in a context and module of its own. *)
let emit_env ?(pack = false) ?(triple = "x86_64-unknown-linux-gnu") () =
  let ctx = Llvm.create_context () in
  let m = Llvm.create_module ctx "unit" in
  let tags = Codegen__Emit.tags ctx in
  {
    Codegen__Emit.ctx;
    m;
    ptr = Llvm.pointer_type ctx;
    i64 = Llvm.i64_type ctx;
    funcs = Hashtbl.create 1;
    abis = Hashtbl.create 1;
    registers = Codegen__Emit.registers triple;
    pack;
    passings = Hashtbl.create 1;
    results = Codegen__Emit.results triple;
    returnings = Hashtbl.create 1;
    globals = Hashtbl.create 1;
    walks = None;
    handle_tag = fst tags;
    value_tag = snd tags;
  }

let dispose (env : Codegen__Emit.env) =
  Llvm.dispose_module env.m;
  Llvm.dispose_context env.ctx

let long_arrays () =
  let env = emit_env () in
  let t = Codegen__Emit.lltype env (Cgt.Nodes.Ty.Array (Cgt.Nodes.Ty.I1, 4294967297)) in
  check "an array of 2^32 + 1 elements keeps its length" (Codegen__Emit.array_length t = 4294967297);
  check "its parts saturate past LLVM's limit"
    (Codegen__Big_moves.parts t = Codegen__Big_moves.most_parts + 1);
  check "a sum's payload room keeps its length"
    (Codegen__Emit.array_length
       (Codegen__Emit.struct_element_types
          (Codegen__Emit.lltype env (Cgt.Nodes.Ty.Sum [ Cgt.Nodes.Ty.Array (Cgt.Nodes.Ty.I64, 1 lsl 33) ]))).(1)
    = 1 lsl 33);
  dispose env

(* How many registers a value takes as itself: one per scalar piece, on the
   CGT type (docs/design/lowering.md §9). *)
let counted_pieces () =
  let module T = Cgt.Nodes.Ty in
  let count = Codegen__Emit.pieces in
  check "Unit takes none" (count T.Void = 0);
  check "a scalar takes one" (List.for_all (fun t -> count t = 1) [ T.I1; T.I32; T.I64; T.F32; T.F64; T.Ptr ]);
  check "a handle takes three" (count T.Handle = 3);
  check "a struct takes its members'" (count (T.Struct [ T.I32; T.I32; T.I32; T.I32 ]) = 4);
  check "a struct's Unit member takes none" (count (T.Struct [ T.I64; T.Void ]) = 1);
  check "an empty struct takes none" (count (T.Struct []) = 0);
  check "a nested struct takes its members' members'" (count (T.Struct [ T.Struct [ T.I64; T.F64 ]; T.Handle ]) = 5);
  check "an enum takes its tag" (count (T.Sum [ T.Void; T.Void ]) = 1);
  check "a variant takes its tag and each payload word"
    (count (T.Sum [ T.I64; T.Struct [ T.I64; T.I64 ]; T.Void ]) = 3);
  check "an array takes its element's times its length" (count (T.Array (T.Struct [ T.I64; T.I32 ], 5)) = 10);
  check "an array of Unit takes none" (count (T.Array (T.Void, 7)) = 0);
  check "65,536 I64s take 65,536" (count (T.Array (T.I64, 65536)) = 65536);
  let floats = Codegen__Emit.floats in
  check "a handle has no floating-point piece" (floats T.Handle = 0);
  check "a struct has its members' floating-point pieces" (floats (T.Struct [ T.F64; T.I64; T.F32 ]) = 2);
  check "an array has its element's times its length" (floats (T.Array (T.Struct [ T.F64; T.I32 ], 3)) = 3);
  check "a variant's payload words are not floating-point" (floats (T.Sum [ T.F64; T.Void ]) = 0)

(* Which way each type crosses, per target and with packing. *)
let passings () =
  let module T = Cgt.Nodes.Ty in
  let module E = Codegen__Emit in
  check "x86-64 Linux gives two registers" (E.registers "x86_64-unknown-linux-gnu" = 2);
  check "AArch64 macOS gives two" (E.registers "aarch64-apple-darwin" = 2);
  check "x86-64 Windows gives one" (E.registers "x86_64-unknown-windows-gnu" = 1);
  check "AArch64 Windows gives two" (E.registers "aarch64-unknown-windows-msvc" = 2);
  let pair = T.Struct [ T.I64; T.I64 ] and small = T.Struct [ T.I32; T.I32; T.I32 ] in
  let linux = emit_env () and windows = emit_env ~triple:"x86_64-unknown-windows-gnu" () in
  let packed = emit_env ~pack:true () and packed_windows = emit_env ~pack:true ~triple:"x86_64-pc-windows-msvc" () in
  check "a scalar passes as itself" (E.passing windows T.I64 = E.Itself);
  check "two pieces pass as themselves on Linux" (E.passing linux pair = E.Itself);
  check "two pieces pass by address on Windows" (E.passing windows pair = E.Address);
  check "three pieces pass by address" (E.passing linux small = E.Address);
  check "a handle passes by address" (E.passing linux T.Handle = E.Address);
  check "65,536 I64s pass by address" (E.passing linux (T.Array (T.I64, 65536)) = E.Address);
  check "packed, three I32s are two words" (E.passing packed small = E.Words 2);
  check "packed, three bytes are one word" (E.passing packed (T.Struct [ T.I1; T.I1; T.I1 ]) = E.Words 1);
  check "packed, a scalar is itself" (E.passing packed T.F64 = E.Itself);
  check "packed, three words go by address" (E.passing packed T.Handle = E.Address);
  check "packed on Windows, one word fits" (E.passing packed_windows (T.Sum [ T.Void; T.Void ]) = E.Words 1);
  check "packed on Windows, two words go by address" (E.passing packed_windows small = E.Address);
  List.iter dispose [ linux; windows; packed; packed_windows ]

(* Which way each type comes back as a result: within three pieces, at
   most two of them floating-point, on x86-64 and AArch64, and within the
   argument limit elsewhere. *)
let returnings () =
  let module T = Cgt.Nodes.Ty in
  let module E = Codegen__Emit in
  check "x86-64 Linux returns three pieces, two floating" (E.results "x86_64-unknown-linux-gnu" = (3, 2));
  check "x86-64 Windows returns as many" (E.results "x86_64-unknown-windows-gnu" = (3, 2));
  check "AArch64 macOS returns as many" (E.results "arm64-apple-macosx" = (3, 2));
  check "RISC-V returns what it passes" (E.results "riscv64-unknown-linux-gnu" = (2, 2));
  let linux = emit_env () and windows = emit_env ~triple:"x86_64-unknown-windows-gnu" () in
  let packed = emit_env ~pack:true () in
  check "a handle comes back as itself" (E.returning linux T.Handle = E.Itself);
  check "a handle comes back as itself on Windows" (E.returning windows T.Handle = E.Itself);
  check "a two-word variant comes back as itself"
    (E.returning linux (T.Sum [ T.I64; T.Struct [ T.I64; T.I64 ] ]) = E.Itself);
  check "four pieces come back by address"
    (E.returning linux (T.Struct [ T.I32; T.I32; T.I32; T.I32 ]) = E.Address);
  check "two floats come back as themselves" (E.returning linux (T.Struct [ T.F64; T.F64; T.I64 ]) = E.Itself);
  check "three floats come back by address" (E.returning linux (T.Struct [ T.F64; T.F64; T.F64 ]) = E.Address);
  check "65,536 I64s come back by address" (E.returning linux (T.Array (T.I64, 65536)) = E.Address);
  check "packed, a handle comes back as three words" (E.returning packed T.Handle = E.Words 3);
  check "packed, four words come back by address" (E.returning packed (T.Array (T.I64, 4)) = E.Address);
  List.iter dispose [ linux; windows; packed ]

(* The backstop: a function whose own type still passes or returns an
   aggregate too large to move as one value is a broken invariant. *)
let backstop () =
  let ctx = Llvm.create_context () in
  let m = Llvm.create_module ctx "backstop" in
  let i64 = Llvm.i64_type ctx in
  let big = Codegen__Emit.array_type i64 65536 in
  let layout = Llvm_target.DataLayout.of_string "e-m:e-i64:64-n8:16:32:64-S128" in
  ignore (Llvm.declare_function "small" (Llvm.function_type i64 [| Codegen__Emit.array_type i64 3 |]) m);
  check "a signature of small aggregates passes" (Codegen__Big_moves.rewrite layout m = Ok ());
  ignore (Llvm.declare_function "takes" (Llvm.function_type i64 [| big |]) m);
  raises_bug "a parameter of 65,536 parts is a bug" (fun () -> Codegen__Big_moves.rewrite layout m);
  Llvm.dispose_module m;
  let m = Llvm.create_module ctx "backstop" in
  ignore (Llvm.declare_function "gives" (Llvm.function_type big [||]) m);
  raises_bug "a result of 65,536 parts is a bug" (fun () -> Codegen__Big_moves.rewrite layout m);
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

(* A control character in a file name or a message reaches the terminal as an
   escape, in every location form and in an internal error, never as itself. *)
let escaped_locations () =
  let name = "dir\027]0;title\007/a\226\128\174\t.zn" in
  let message = "unknown name `x\027[2J\t`" in
  let pos = { Lexing.pos_fname = name; pos_lnum = 1; pos_bol = 0; pos_cnum = 0 } in
  let at = Source.Span.of_loc (pos, { pos with Lexing.pos_cnum = 1 }) in
  let shown = "dir\\x1b]0;title\\x07/a\\u202e\\x09.zn" in
  let quiet text =
    String.for_all (fun c -> c = '\n' || Char.code c >= 0x20 && Char.code c < 0x7F) text
  in
  List.iter
    (fun (form, names_file, text) ->
      check (form ^ " escapes its controls") (quiet text);
      check (form ^ " shows the escaped message") (contains text "unknown name `x\\x1b[2J\\x09`");
      if names_file then check (form ^ " escapes the file name") (contains text shown))
    [
      ("a span", true, Diagnostic.render ~source:"x\n" (Diagnostic.error at message));
      ("a file", true, Diagnostic.render ~source:"" (Diagnostic.in_file name message));
      ("a directory", true, Diagnostic.render ~source:"" (Diagnostic.in_directory name message));
      ("an invocation", false, Diagnostic.render ~source:"" (Diagnostic.about_invocation message));
      ("an internal error", true, Diagnostic.render_internal ~span:at message);
    ]

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
  Traversals.run check;
  signatures ();
  overloads ();
  string_constructors ();
  type_layout ();
  growing_types ();
  fixpoint_chain ();
  runtime_abi ();
  probed_abi ();
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
  replayed_outputs ();
  global_member ();
  signed_zero ();
  twice ();
  at_once ();
  snapshot_reads ();
  shared_walks ();
  target_cpus ();
  sixty_four_bit ();
  checked_sizes ();
  long_arrays ();
  counted_pieces ();
  passings ();
  returnings ();
  backstop ();
  fixture_pairing ();
  escaped_locations ();
  Builds.cached_runtime ();
  Builds.linked_in_process ();
  Builds.bundled_runtime ();
  Builds.fatal_link ();
  rewriting_keeps_others_files ();
  stamps_are_checked ();
  disposed_modules ();
  repeated_builds ();
  if !failures > 0 then begin
    Printf.printf "%d failed\n" !failures;
    exit 1
  end
