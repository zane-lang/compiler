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
let int = prim "Int"
let float = prim "Float"
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
    (S.to_string f = "@primitives$Float f(@primitives$Int)");
  let m = signature ~kind:S.Method "size" [ ("this", named "Bag"); ("n", int) ] int in
  check "a method prints its subject" (S.to_string m = "@primitives$Int size(this app$Bag, @primitives$Int)");
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

(* ---------------------------------------------------------------------- *)
(* Type layout                                                            *)
(* ---------------------------------------------------------------------- *)

let type_layout () =
  let st = State.create ~library:None ~stamp:(fun _ -> "") ~stamped:(fun _ -> false) in
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
  check "a division by zero stops the fold"
    (stops (fun () -> bin C.Expr.Div C.Ty.I64 (i64 1L) (i64 0L)));
  let f x = Value.VFloat x in
  check "NaN is not equal to itself" (bin C.Expr.Eq C.Ty.F64 (f Float.nan) (f Float.nan) = Value.VBool false);
  check "NaN is not less than anything" (bin C.Expr.Less C.Ty.F64 (f Float.nan) (f 1.) = Value.VBool false);
  check "negative zero equals zero" (bin C.Expr.Eq C.Ty.F64 (f (-0.)) (f 0.) = Value.VBool true);
  check "Bool + is or" (bin C.Expr.Add C.Ty.I1 (Value.VBool true) (Value.VBool false) = Value.VBool true);
  check "Bool * is and" (bin C.Expr.Mul C.Ty.I1 (Value.VBool true) (Value.VBool false) = Value.VBool false);
  check "~ wraps the most negative I32" (Eval.flip C.Ty.I32 (i32 (-2147483648L)) = i32 (-2147483648L))

(* Every runtime function is in a class, and the outputs are the three
   docs/design/optimization.md O3 names. No runtime function is an input
   yet. *)
let intrinsic_classes () =
  let outputs =
    List.filter (fun fn -> Intrinsics.classify fn = Intrinsics.Output) Cgt.Runtime.all
  in
  check "print and the thread count are the outputs"
    (List.sort compare outputs
    = List.sort compare Cgt.Runtime.[ Print; Set_threads; Set_threads_auto ]);
  check "no runtime function is an input yet"
    (not (List.exists (fun fn -> Intrinsics.classify fn = Intrinsics.Input) Cgt.Runtime.all))

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
    memo = Hashtbl.create 8;
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
  check "a call is remembered by its arguments" (Hashtbl.mem prog.Eval.memo ("double", [ Value.Int 21L ]));
  let again = Eval.start prog in
  ignore (Eval.call again "double" [ Value.VInt 21L ]);
  check "a remembered call outputs again" (List.rev again.Eval.outputs = Eval.[ Print "a"; Print "b" ]);
  let forever = C.Stat.Repeat { count = i64 Int64.max_int; body = [] } in
  let fr = { Eval.locals = Hashtbl.create 1; outer = None } in
  check "a spent budget stops the run" (stops (fun () -> Eval.stat (Eval.start prog) fr forever));
  let state = e (C.Expr.Global "k.state") C.Ty.Ptr in
  let begin_ = e (C.Expr.Runtime { fn = Cgt.Runtime.Constant_begin; args = [ state ] }) C.Ty.I64 in
  check "where a constant is made stays" (stops (fun () -> Eval.expr (Eval.start prog) fr begin_))

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
  let f = Fold.func (program []) (Hashtbl.create 1) (func "f" [] body) in
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
  let f = Fold.func (program []) (Hashtbl.create 1) (func "f" [] body) in
  check "a loop over a known local folds to what it wrote"
    (f.C.Func.body = [ C.Stat.Let { id = 1; value = i64 2L }; C.Stat.assign 1 (i64 16L); C.Stat.Return (i64 16L) ])

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

let () =
  ty ();
  signatures ();
  overloads ();
  type_layout ();
  runtime_abi ();
  folded_arithmetic ();
  intrinsic_classes ();
  materialized ();
  evaluated ();
  stored_in_place ();
  kept_store ();
  folded_function ();
  twice ();
  at_once ();
  if !failures > 0 then begin
    Printf.printf "%d failed\n" !failures;
    exit 1
  end
