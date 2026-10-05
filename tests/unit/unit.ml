module Ty = Tst.Ty
module S = Tst.Signature
module T = Tst.Nodes
module Overloads = Tst__Overloads
module State = Cgt__State
module Type_layout = Cgt__Type_layout

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
  check "equal keeps a guest apart" (not (Ty.equal (Ty.Guest int) int));
  check "assignable looks through a guest" (Ty.assignable ~dst:int ~src:(Ty.Guest int));
  check "equal tells primitives apart" (not (Ty.equal int float));
  check "Error equals anything" (Ty.equal Ty.Error (named "Point"));
  check "parameters are equal by id, not name"
    (not (Ty.equal (Ty.Param t) (Ty.Param { t with Ty.id = t.Ty.id + 1000 })));
  check "strip_guest" (Ty.strip_guest (Ty.Guest int) = int);
  check "is_guest" (Ty.is_guest (Ty.Guest int) && not (Ty.is_guest int));
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
    (Ty.equal (Ty.instantiate [ t ] [ Ty.Type int ] (Ty.Guest (Ty.Param t))) (Ty.Guest int));
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
  Overloads.resolve candidates (fun s -> Overloads.positional (List.map actual args) s)

let name_of = function
  | Overloads.Resolved o -> o.Overloads.sig_.S.name
  | Overloads.No_match -> "no match"
  | Overloads.Ambiguous _ -> "ambiguous"

let overloads () =
  Tst__Env.reset ();
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

let () =
  ty ();
  signatures ();
  overloads ();
  type_layout ();
  twice ();
  if !failures > 0 then begin
    Printf.printf "%d failed\n" !failures;
    exit 1
  end
