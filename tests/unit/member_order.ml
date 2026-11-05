(* Where lowering places a struct's members (docs/design/lowering.md L5):
   in decreasing order of alignment, those of one alignment in declaration
   order, and a member reached by its place there; and a C-compatible value
   type rebuilt in C's declaration order as it crosses into C and back
   (docs/design/ffi.md F10). *)

open Support
module Ty = Tst.Ty
module T = Tst.Nodes
module State = Cgt__State
module Type_layout = Cgt__Type_layout
module N = Cgt.Nodes.Ty
module L = Cgt.Nodes.Layout

let span = Source.Span.of_loc (Lexing.dummy_pos, Lexing.dummy_pos)
let prim name = Ty.Intrinsic { namespace = "primitives"; name; args = [] }
let int = prim "I64"
let named ?(args = []) name = Ty.Named ({ Ty.package = "app"; name }, args)

let layouts () =
  let st = State.create ~region:Cgt.Runtime.default_fixed_region ~import_bodies:false ~library:false ~exclusive:false ~exports:(fun _ -> false) ~stamp:(fun _ -> "") ~stamped:(fun _ -> false) in
  let t = Ty.fresh_param ~name:"T" ~kind:Ty.Type_kind in
  Hashtbl.replace st.State.types ("app", "Box")
    ([ t ], T.Decl.Struct [ ("item", Ty.Param t); ("count", int) ], false);
  let box = named "Box" ~args:[ Ty.Type (prim "F64") ] in
  Hashtbl.replace st.State.types ("app", "Mixed")
    ( [],
      T.Decl.Struct
        [ ("flag", prim "Bool"); ("n", int); ("small", prim "I32"); ("s", prim "String"); ("other", prim "I32") ],
      false );
  let mixed = named "Mixed" in
  check "a struct's members are ordered by alignment"
    (Type_layout.ty st span mixed = N.Struct [ N.I64; N.Handle; N.I32; N.I32; N.I1 ]);
  check "a reordered struct has no padding between its members"
    (N.size_align (Type_layout.ty st span mixed) = (48, 8)
    && N.size_align (N.Struct [ N.I1; N.I64; N.I32; N.Handle; N.I32 ]) = (56, 8));
  check "a member's index is where its layout places it"
    (List.map (Type_layout.member_index st mixed) [ 0; 1; 2; 3; 4 ] = [ 4; 0; 2; 1; 3 ]);
  check "a member's index reads through a roaming owner"
    (Type_layout.member_index st (Ty.Roaming mixed) 0 = 4);
  check "a member's positions are at its place in the layout"
    (match Type_layout.positions st span mixed 0 [] with [ { L.kind = L.Text; offset = 8; _ } ] -> true | _ -> false);
  check "an instance is ordered by its own members"
    (Type_layout.ty st span (named "Box" ~args:[ Ty.Type (prim "I32") ]) = N.Struct [ N.I64; N.I32 ]
    && Type_layout.member_index st (named "Box" ~args:[ Ty.Type (prim "I32") ]) 0 = 1
    && Type_layout.member_index st box 0 = 0);
  check "members already in order stay where they are"
    (N.order [ N.I64; N.I32; N.I32; N.I1 ] = [| 0; 1; 2; 3 |] && not (N.reordered [ N.I64; N.I32; N.I1 ]));
  check "members of one alignment keep their declaration order"
    (N.order [ N.I32; N.F64; N.F32; N.Ptr; N.I32 ] = [| 2; 0; 3; 1; 4 |])

(* A C-compatible value type crosses into C with its fields in declaration
   order, rebuilt from its own layout's order, and back. *)
let crossings () =
  let module N = Cgt.Nodes in
  let module Cb = N.Callback in
  let tagged = Cb.Record [ (Cb.Scalar N.Ty.I32, None); (Cb.Scalar N.Ty.I64, None) ] in
  let nest = Cb.Record [ (Cb.Scalar N.Ty.I32, None); (tagged, None); (Cb.Scalar N.Ty.F32, Some 3) ] in
  let local ty = { N.Expr.node = N.Expr.Local 1; ty } in
  check "a struct's Zane layout is ordered, its C layout declared"
    (Cb.zane tagged = N.Ty.Struct [ N.Ty.I64; N.Ty.I32 ] && Cb.c tagged = N.Ty.Struct [ N.Ty.I32; N.Ty.I64 ]);
  check "a struct of one field is the field on both sides"
    (Cb.zane (Cb.Record [ (tagged, None) ]) = Cb.zane tagged && Cb.c (Cb.Record [ (tagged, None) ]) = Cb.c tagged);
  check "a reordered struct moves; one in C's order does not"
    (Cb.moved tagged && Cb.moved nest
    && not (Cb.moved (Cb.Record [ (Cb.Scalar N.Ty.I64, None); (Cb.Scalar N.Ty.I32, None) ])));
  check "into C, each field is read from its place in the Zane layout"
    (match Cb.to_c tagged (local (Cb.zane tagged)) with
    | { N.Expr.node = N.Expr.Record [ (0, { node = N.Expr.Member { index = 1; _ }; ty = N.Ty.I32 }); (1, { node = N.Expr.Member { index = 0; _ }; ty = N.Ty.I64 }) ]; ty }
      ->
        ty = Cb.c tagged
    | _ -> false);
  check "back from C, each field goes to its place in the Zane layout"
    (match Cb.of_c tagged (local (Cb.c tagged)) with
    | { N.Expr.node = N.Expr.Record [ (1, { node = N.Expr.Member { index = 0; _ }; _ }); (0, { node = N.Expr.Member { index = 1; _ }; _ }) ]; ty }
      ->
        ty = Cb.zane tagged
    | _ -> false);
  check "a nested struct is rebuilt in turn"
    (match Cb.to_c nest (local (Cb.zane nest)) with
    | { N.Expr.node = N.Expr.Record [ _; (1, { node = N.Expr.Record _; ty = inner }); (2, { node = N.Expr.Member _; ty = N.Ty.Array (N.Ty.F32, 3) }) ]; ty }
      ->
        inner = Cb.c tagged && ty = Cb.c nest
    | _ -> false);
  check "a struct already in C's order is passed as it is"
    (let s = Cb.Record [ (Cb.Scalar N.Ty.F64, None); (Cb.Scalar N.Ty.I32, None) ] in
     let v = local (Cb.zane s) in
     Cb.to_c s v == v)

let run () =
  layouts ();
  crossings ()
