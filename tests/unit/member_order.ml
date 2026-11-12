(* Where lowering places a struct's members (docs/design/lowering.md L5):
   in decreasing order of alignment, those of one alignment in declaration
   order, packed when C's layout would pad them, and a member reached by
   its place there; how a sum is laid out, packed with a one-byte tag or
   its tag in a spare byte of its payload; and a C-compatible value type
   rebuilt in C's declaration order as it crosses into C and back
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
  check "a struct's members are ordered by alignment, and packed when C would pad them"
    (Type_layout.ty st span mixed = N.Packed (N.Struct [ N.I64; N.Handle; N.I32; N.I32; N.I1 ]));
  check "a packed struct has no padding, its tail included, and alignment 1"
    (N.size_align (Type_layout.ty st span mixed) = (41, 1)
    && N.size_align (N.Struct [ N.I1; N.I64; N.I32; N.Handle; N.I32 ]) = (56, 8));
  check "a struct with no padding keeps its natural layout"
    (N.tight (N.Struct [ N.I64; N.I32; N.I32 ]) = N.Struct [ N.I64; N.I32; N.I32 ]
    && N.size_align (N.tight (N.Struct [ N.I64; N.I32; N.I32 ])) = (16, 8));
  check "a sum with no spare byte is packed, its tag one byte before its room"
    (N.tight (N.Sum [ N.Void; N.I64 ]) = N.Packed (N.Sum [ N.Void; N.I64 ])
    && N.size_align (N.Packed (N.Sum [ N.Void; N.I64 ])) = (9, 1));
  check "a sum whose one payload has a spare byte keeps its tag there"
    (let payload = N.tight (N.Struct [ N.I64; N.I1 ]) in
     let sum = N.Sum [ N.Void; payload ] in
     N.tight sum = sum
     && N.size_align sum = (9, 1)
     && match N.byte_niche [ N.Void; payload ] with
        | Some { N.case = 1; at = 8; first = 2; count = 1; _ } -> true
        | _ -> false);
  check "a sum's spare byte may be a packed sum's tag"
    (let inner = N.Packed (N.Sum [ N.Void; N.I64 ]) in
     match N.byte_niche [ N.Void; inner ] with Some { N.at = 0; first = 2; count = 1; _ } -> true | _ -> false);
  check "a sum of more cases than a byte tells apart keeps its 4-byte tag"
    (let cases n = List.init n (fun _ -> N.Void) in
     N.tight (N.Sum (cases 300)) = N.Sum (cases 300) && N.tight (N.Sum (cases 256)) = N.Packed (N.Sum (cases 256)));
  check "a sum too large to measure is left for the size check"
    (let sum = N.Sum [ N.Void; N.Struct [ N.Array (N.I64, 1 lsl 46); N.I1 ] ] in
     N.tight sum = sum);
  check "a spare byte past what a layout's tag holds is not a byte niche"
    (N.byte_niche [ N.Void; N.Struct [ N.Array (N.I64, 1 lsl 21); N.I1 ] ] = None
     && N.byte_niche [ N.Void; N.Struct [ N.Array (N.I64, (1 lsl 21) - 1); N.I1 ] ] <> None);
  check "optional Bools nested sixty deep, each in a struct, are laid out in time"
    (let rec deep k t = if k = 0 then t else deep (k - 1) (N.Sum [ N.Void; N.Struct [ N.I32; t ] ]) in
     match deep 60 N.I1 with N.Sum ts -> N.byte_niche ts <> None | _ -> false);
  check "a member's index is where its layout places it"
    (List.map (Type_layout.member_index st mixed) [ 0; 1; 2; 3; 4 ] = [ 4; 0; 2; 1; 3 ]);
  check "a member's index reads through a roaming owner"
    (Type_layout.member_index st (Ty.Roaming mixed) 0 = 4);
  check "a member's positions are at its place in the layout"
    (match Type_layout.positions st span mixed 0 [] with [ { L.kind = L.Text; offset = 8; _ } ] -> true | _ -> false);
  check "an instance is ordered by its own members"
    (Type_layout.ty st span (named "Box" ~args:[ Ty.Type (prim "I32") ]) = N.Packed (N.Struct [ N.I64; N.I32 ])
    && Type_layout.member_index st (named "Box" ~args:[ Ty.Type (prim "I32") ]) 0 = 1
    && Type_layout.member_index st box 0 = 0);
  check "members already in order stay where they are"
    (N.order [ N.I64; N.I32; N.I32; N.I1 ] = [| 0; 1; 2; 3 |] && not (N.reordered [ N.I64; N.I32; N.I1 ]));
  (* The C conversion lays a C-compatible type out from its shape alone,
     so it must agree with lowering, an array of none included. *)
  Hashtbl.replace st.State.types ("app", "Gap")
    ( [],
      T.Decl.Struct
        [
          ("a", prim "I32");
          ("empty", Ty.Intrinsic { namespace = "primitives"; name = "Array"; args = [ Ty.Type int; Ty.Number (Ty.Known 0) ] });
          ("b", int);
        ],
      false );
  let module Cb = Cgt.Nodes.Callback in
  let gap = Cb.Record [ (Cb.Scalar N.I32, None); (Cb.Scalar N.I64, Some 0); (Cb.Scalar N.I64, None) ] in
  check "the C conversion's Zane layout is lowering's, an empty array included"
    (Cb.zane gap = Type_layout.ty st span (named "Gap") && Cb.zane gap = N.Packed (N.Struct [ N.I64; N.I32; N.Array (N.Void, 0) ]));
  check "a member past the size limit is ordered, and its struct still refused"
    (N.order [ N.I32; N.Array (N.I64, 1 lsl 60) ] = [| 1; 0 |]
    && match N.size_align (N.Struct [ N.Array (N.I64, 1 lsl 60); N.I32 ]) with _ -> false | exception N.Too_large -> true);
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
  check "a struct's Zane layout is ordered and packed, its C layout declared"
    (Cb.zane tagged = N.Ty.Packed (N.Ty.Struct [ N.Ty.I64; N.Ty.I32 ]) && Cb.c tagged = N.Ty.Struct [ N.Ty.I32; N.Ty.I64 ]);
  check "a struct of one field is the field on both sides"
    (Cb.zane (Cb.Record [ (tagged, None) ]) = Cb.zane tagged && Cb.c (Cb.Record [ (tagged, None) ]) = Cb.c tagged);
  check "a reordered struct moves; one in C's order moves only when C pads it"
    (Cb.moved tagged && Cb.moved nest
    && Cb.moved (Cb.Record [ (Cb.Scalar N.Ty.I64, None); (Cb.Scalar N.Ty.I32, None) ])
    && not (Cb.moved (Cb.Record [ (Cb.Scalar N.Ty.I64, None); (Cb.Scalar N.Ty.I32, None); (Cb.Scalar N.Ty.I32, None) ])));
  check "a struct in C's order still moves when it holds an array of none"
    (let tail = Cb.Record [ (Cb.Scalar N.Ty.I64, None); (Cb.Scalar N.Ty.I64, Some 0) ] in
     Cb.moved tail && Cb.moved (Cb.Record [ (tail, None) ])
     && Cb.moved (Cb.Record [ (Cb.Scalar N.Ty.I32, None); (tail, None) ])
     && not (Cb.moved (Cb.Record [ (Cb.Scalar N.Ty.I64, None); (Cb.Scalar N.Ty.I64, Some 2) ])));
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
  check "a struct already in C's order, with no padding, is passed as it is"
    (let s = Cb.Record [ (Cb.Scalar N.Ty.F64, None); (Cb.Scalar N.Ty.I32, None); (Cb.Scalar N.Ty.F32, None) ] in
     let v = local (Cb.zane s) in
     Cb.to_c s v == v)

let run () =
  layouts ();
  crossings ()
