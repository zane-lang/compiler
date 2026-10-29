(* The shared traversals, Tst.Traverse and Cgt.Traverse, on one node of each
   constructor: what they say the node is made of is exactly its children, in
   the order they run. Every child is a node of its own, compared by identity,
   so a child left out, given twice or given in the wrong context fails here
   rather than in an analysis. [tag] numbers the constructors; it matches
   every one, so a new constructor does not compile here until it has a
   number, and [tags] then fails until it has a sample. *)

module T = Tst.Nodes
module P = Tst.Traverse
module C = Cgt.Nodes
module CP = Cgt.Traverse

let span = Source.Span.of_loc (Lexing.dummy_pos, Lexing.dummy_pos)

(* Whether the samples cover every number [tag] gives, each once. *)
let tags tag count samples = List.sort compare (List.map tag samples) = List.init count Fun.id

(* ---------------------------------------------------------------------- *)
(* The typed syntax tree                                                  *)
(* ---------------------------------------------------------------------- *)

let tst_tag : T.Expr.node -> int = function
  | T.Expr.Integer_lit _ -> 0
  | T.Expr.Decimal_lit _ -> 1
  | T.Expr.Text_lit _ -> 2
  | T.Expr.Bool_lit _ -> 3
  | T.Expr.Array_lit _ -> 4
  | T.Expr.Map_lit _ -> 5
  | T.Expr.Var _ -> 6
  | T.Expr.Type_arg _ -> 7
  | T.Expr.Enum_member _ -> 8
  | T.Expr.Case _ -> 9
  | T.Expr.Construct _ -> 10
  | T.Expr.Construct_fields _ -> 11
  | T.Expr.Field _ -> 12
  | T.Expr.Case_read _ -> 13
  | T.Expr.Map_read _ -> 14
  | T.Expr.Subscript _ -> 15
  | T.Expr.Init _ -> 16
  | T.Expr.Spawn _ -> 17
  | T.Expr.Match _ -> 18
  | T.Expr.Call _ -> 19
  | T.Expr.Call_value _ -> 20
  | T.Expr.Op _ -> 21
  | T.Expr.Flip _ -> 22
  | T.Expr.Coerce _ -> 23
  | T.Expr.Lambda _ -> 24
  | T.Expr.Invalid -> 25
  | T.Expr.Foreign_global _ -> 26

let tst_count = 27

let tst_stat_tag : T.Stat.node -> int = function
  | T.Stat.Expr _ -> 0
  | T.Stat.Spawn _ -> 1
  | T.Stat.Let _ -> 2
  | T.Stat.Assign _ -> 3
  | T.Stat.Abort _ -> 4
  | T.Stat.Return _ -> 5
  | T.Stat.Resolve _ -> 6

let tst_stat_count = 7

let fresh = ref 0

let leaf () =
  incr fresh;
  { T.Expr.node = T.Expr.Integer_lit (string_of_int !fresh); ty = Tst.Ty.Error; span }

let block () = { T.Block.stats = [ { T.Stat.node = T.Stat.Expr (leaf ()); span } ]; span }
let verb = { T.Verb_ref.owner = Tst.Signature.Intrinsic "@test$verb"; name = "verb"; instance = [] }
let local = { T.Local.id = 1; name = "x"; ty = Tst.Ty.Error; span }
let field value = { T.Field_value.name = "f"; slot = 0; value; span }

let same_part a b =
  match (a, b) with
  | P.Same x, P.Same y -> x == y
  | P.Arm x, P.Arm y | P.Handler x, P.Handler y | P.Block x, P.Block y | P.Lambda x, P.Lambda y -> x == y
  | _ -> false

(* One expression of each constructor, with the parts it is made of. *)
let tst_samples () =
  let x () =
    let e = leaf () in
    (e, P.Same e)
  in
  let h () =
    let b = block () in
    ({ T.Handler.binder = None; body = b; span }, P.Handler b)
  in
  let b () =
    let b = block () in
    (b, P.Block b)
  in
  let none node = (node, []) in
  let (a, pa), (c, pc), (k, pk), (v, pv) = (x (), x (), x (), x ()) in
  let (hh, ph), (bb, pb) = (h (), b ()) in
  let arm = block () in
  let lam = block () in
  [
    none (T.Expr.Integer_lit "1");
    none (T.Expr.Decimal_lit "1.5");
    (T.Expr.Text_lit [ T.Expr.Fragment "t"; T.Expr.Interpolation a; T.Expr.Interpolation c ], [ pa; pc ]);
    none (T.Expr.Bool_lit true);
    (T.Expr.Array_lit [ a; c ], [ pa; pc ]);
    (T.Expr.Map_lit [ (a, c); (k, v) ], [ pa; pc; pk; pv ]);
    none (T.Expr.Var (T.Name_ref.Intrinsic "x"));
    none (T.Expr.Type_arg Tst.Ty.Error);
    none (T.Expr.Enum_member "e");
    (T.Expr.Case { case = "c"; payload = a }, [ pa ]);
    ( T.Expr.Construct { ctor = verb; args = [ T.Arg.Value a; T.Arg.Block bb ]; handler = Some hh },
      [ pa; pb; ph ] );
    ( T.Expr.Construct_fields { ctor = verb; fields = [ field a; field c ]; handler = Some hh },
      [ pa; pc; ph ] );
    (T.Expr.Field { target = a; field = "f"; slot = 0 }, [ pa ]);
    (T.Expr.Case_read { target = a; case = "c"; handler = hh }, [ pa; ph ]);
    (T.Expr.Map_read { target = a; map = 0; property = "p" }, [ pa ]);
    (T.Expr.Subscript { target = a; impl = verb; args = [ c; k ] }, [ pa; pc; pk ]);
    (T.Expr.Init [ field a; field c ], [ pa; pc ]);
    (T.Expr.Spawn a, [ pa ]);
    ( T.Expr.Match
        {
          scrutinees = [ a; c ];
          arms = [ { T.Arm.patterns = []; body = arm; span } ];
          handler = Some hh;
        },
      [ pa; pc; P.Arm arm; ph ] );
    ( T.Expr.Call { callee = verb; args = [ T.Arg.Value a; T.Arg.Block bb ]; handler = Some hh },
      [ pa; pb; ph ] );
    (T.Expr.Call_value { callee = a; args = [ T.Arg.Value c; T.Arg.Block bb ]; handler = Some hh }, [ pa; pc; pb; ph ]);
    ( T.Expr.Op { op = Sst.Nodes.Operator.Add; impl = verb; left = a; right = c; swapped = false; handler = Some hh },
      [ pa; pc; ph ] );
    (T.Expr.Flip { impl = verb; value = a; handler = Some hh }, [ pa; ph ]);
    (T.Expr.Coerce { ctor = verb; value = a }, [ pa ]);
    (T.Expr.Lambda { params = []; body = lam }, [ P.Lambda lam ]);
    none T.Expr.Invalid;
    none (T.Expr.Foreign_global { symbol = "zane_fs"; package = "fs" });
  ]

let tst_stat_samples () =
  let a = leaf () and c = leaf () in
  [
    (T.Stat.Expr a, [ a ]);
    (T.Stat.Spawn a, [ a ]);
    (T.Stat.Let { local; value = a }, [ a ]);
    (T.Stat.Assign { target = a; value = c }, [ a; c ]);
    (T.Stat.Abort a, [ a ]);
    (T.Stat.Return a, [ a ]);
    (T.Stat.Resolve a, [ a ]);
  ]

let tst check =
  let samples = tst_samples () in
  check "every TST expression constructor has a sample" (tags (fun (n, _) -> tst_tag n) tst_count samples);
  List.iter
    (fun (node, expected) ->
      let got = P.parts { T.Expr.node; ty = Tst.Ty.Error; span } in
      check
        (Printf.sprintf "Tst.Traverse.parts of expression constructor %d" (tst_tag node))
        (List.length got = List.length expected && List.for_all2 same_part got expected))
    samples;
  let stats = tst_stat_samples () in
  check "every TST statement constructor has a sample" (tags (fun (n, _) -> tst_stat_tag n) tst_stat_count stats);
  List.iter
    (fun (node, expected) ->
      let got = P.stat_exprs { T.Stat.node; span } in
      check
        (Printf.sprintf "Tst.Traverse.stat_exprs of statement constructor %d" (tst_stat_tag node))
        (List.length got = List.length expected && List.for_all2 ( == ) got expected))
    stats

(* ---------------------------------------------------------------------- *)
(* The code-generation tree                                               *)
(* ---------------------------------------------------------------------- *)

let cgt_tag : C.Expr.node -> int = function
  | C.Expr.Int _ -> 0
  | C.Expr.Float _ -> 1
  | C.Expr.Bool _ -> 2
  | C.Expr.Text _ -> 3
  | C.Expr.Unit -> 4
  | C.Expr.Local _ -> 5
  | C.Expr.Address _ -> 6
  | C.Expr.Deref _ -> 7
  | C.Expr.Call _ -> 8
  | C.Expr.Call_value _ -> 9
  | C.Expr.Runtime _ -> 10
  | C.Expr.Math _ -> 11
  | C.Expr.Binary _ -> 12
  | C.Expr.Flip _ -> 13
  | C.Expr.Convert _ -> 14
  | C.Expr.Expand _ -> 15
  | C.Expr.Record _ -> 16
  | C.Expr.Member _ -> 17
  | C.Expr.Case _ -> 18
  | C.Expr.Payload _ -> 19
  | C.Expr.Offset _ -> 20
  | C.Expr.Take _ -> 21
  | C.Expr.Copy _ -> 22
  | C.Expr.Box _ -> 23
  | C.Expr.Layout _ -> 24
  | C.Expr.Function _ -> 25
  | C.Expr.Global _ -> 26
  | C.Expr.Snapshot _ -> 27
  | C.Expr.Escape _ -> 28
  | C.Expr.Foreign_call _ -> 29

let cgt_count = 30

let cgt_stat_tag : C.Stat.t -> int = function
  | C.Stat.Let _ -> 0
  | C.Stat.Hold _ -> 1
  | C.Stat.Scope _ -> 2
  | C.Stat.Assign _ -> 3
  | C.Stat.Eval _ -> 4
  | C.Stat.Return _ -> 5
  | C.Stat.If _ -> 6
  | C.Stat.Repeat _ -> 7
  | C.Stat.Switch _ -> 8
  | C.Stat.Leave _ -> 9
  | C.Stat.Store _ -> 10
  | C.Stat.Overwrite _ -> 11
  | C.Stat.Place _ -> 12
  | C.Stat.Reserve _ -> 13
  | C.Stat.Spawn _ -> 14
  | C.Stat.Join _ -> 15

let cgt_stat_count = 16

let cleaf () =
  incr fresh;
  { C.Expr.node = C.Expr.Int (Int64.of_int !fresh); ty = C.Ty.I64 }

let cbody () = [ C.Stat.Eval (cleaf ()) ]

let cgt_samples () =
  let a = cleaf () and c = cleaf () and k = cleaf () in
  let body = cbody () in
  let none node = (node, ([], [])) in
  [
    none (C.Expr.Int 1L);
    none (C.Expr.Float 1.5);
    none (C.Expr.Bool true);
    none (C.Expr.Text "t");
    none C.Expr.Unit;
    none (C.Expr.Local 1);
    none (C.Expr.Address 1);
    (C.Expr.Deref a, ([ a ], []));
    (C.Expr.Call { fn = "f"; args = [ a; c ] }, ([ a; c ], []));
    (C.Expr.Call_value { fn = a; args = [ c; k ] }, ([ a; c; k ], []));
    (C.Expr.Runtime { fn = Cgt.Runtime.Print; args = [ a; c ] }, ([ a; c ], []));
    (C.Expr.Math { fn = Cgt.Math.Bit_and; args = [ a; c ] }, ([ a; c ], []));
    (C.Expr.Foreign_call { thunk = "f.ffi"; args = [ a; c ] }, ([ a; c ], []));
    (C.Expr.Binary { op = C.Expr.Add; left = a; right = c }, ([ a; c ], []));
    (C.Expr.Flip a, ([ a ], []));
    (C.Expr.Convert a, ([ a ], []));
    (C.Expr.Expand { label = 1; body; result = None }, ([], [ body ]));
    (C.Expr.Record [ (0, a); (1, c) ], ([ a; c ], []));
    (C.Expr.Member { value = a; index = 0 }, ([ a ], []));
    (C.Expr.Case { index = 0; payload = a }, ([ a ], []));
    (C.Expr.Payload { value = a; index = 0 }, ([ a ], []));
    (C.Expr.Offset { base = a; within = C.Ty.I64; path = [] }, ([ a ], []));
    (C.Expr.Take { address = a; layout = "l" }, ([ a ], []));
    (C.Expr.Copy { value = a; layout = "l" }, ([ a ], []));
    (C.Expr.Box { value = a; layout = "l" }, ([ a ], []));
    none (C.Expr.Layout "l");
    none (C.Expr.Function "f");
    none (C.Expr.Global "g");
    (C.Expr.Snapshot a, ([ a ], []));
    (C.Expr.Escape { value = a; layout = "l"; exit = None }, ([ a ], []));
  ]

let cgt_stat_samples () =
  let a = cleaf () and c = cleaf () and k = cleaf () in
  let b1 = cbody () and b2 = cbody () in
  let place = { C.Expr.local = 1; deref = false; ty = C.Ty.I64; path = [] } in
  let none s = (s, ([], [])) in
  [
    (C.Stat.Let { id = 1; value = a }, ([ a ], []));
    (C.Stat.Hold { id = 1; scope = 2; value = a; layout = "l" }, ([ a ], []));
    (C.Stat.Scope { id = 1; body = b1 }, ([], [ b1 ]));
    (C.Stat.Assign { place; value = a }, ([ a ], []));
    (C.Stat.Eval a, ([ a ], []));
    (C.Stat.Return a, ([ a ], []));
    (C.Stat.If { cond = a; body = b1 }, ([ a ], [ b1 ]));
    (C.Stat.Repeat { count = a; body = b1 }, ([ a ], [ b1 ]));
    (C.Stat.Switch { value = a; cases = [ (0, b1); (1, b2) ] }, ([ a ], [ b1; b2 ]));
    none (C.Stat.Leave 1);
    (C.Stat.Store { address = a; value = c }, ([ a; c ], []));
    (C.Stat.Overwrite { address = a; value = c; layout = "l"; setters = false }, ([ a; c ], []));
    (C.Stat.Place { address = a; value = c; layout = "l" }, ([ a; c ], []));
    none (C.Stat.Reserve { id = 1; scope = 2; ty = C.Ty.I64; layout = "l" });
    ( C.Stat.Spawn
        { task = 1; scope = 2; thunk = "t"; frame = C.Ty.I64; args = [ a; c; k ]; dest = None; layout = "l" },
      ([ a; c; k ], []) );
    none (C.Stat.Join 1);
  ]

let same_list a b = List.length a = List.length b && List.for_all2 ( == ) a b

let same_parts (es, bs) (es', bs') = same_list es es' && same_list bs bs'

(* What a one-level rewrite visits, in the order it visits it, and whether
   the rebuilt node is made of what the rewrite gave back. *)
let mapped map_parts parts node =
  let seen_e = ref [] and seen_b = ref [] in
  let me x =
    seen_e := x :: !seen_e;
    cleaf ()
  in
  let ms b =
    seen_b := b :: !seen_b;
    cbody ()
  in
  let rebuilt = map_parts me ms node in
  let visited = (List.rev !seen_e, List.rev !seen_b) in
  (visited, parts rebuilt)

let cgt check =
  let samples = cgt_samples () in
  check "every CGT expression constructor has a sample" (tags (fun (n, _) -> cgt_tag n) cgt_count samples);
  List.iter
    (fun (node, expected) ->
      let e = { C.Expr.node; ty = C.Ty.I64 } in
      let name = Printf.sprintf "Cgt.Traverse on expression constructor %d" (cgt_tag node) in
      check (name ^ ": parts") (same_parts (CP.expr_parts e) expected);
      let visited, rebuilt = mapped CP.map_expr_parts CP.expr_parts e in
      check (name ^ ": map visits its parts in order") (same_parts visited expected);
      check (name ^ ": map rebuilds every part")
        (List.length (fst rebuilt) = List.length (fst expected)
        && List.length (snd rebuilt) = List.length (snd expected)
        && not (List.exists (fun x -> List.memq x (fst expected)) (fst rebuilt))
        && not (List.exists (fun b -> List.memq b (snd expected)) (snd rebuilt))))
    samples;
  let stats = cgt_stat_samples () in
  check "every CGT statement constructor has a sample" (tags (fun (s, _) -> cgt_stat_tag s) cgt_stat_count stats);
  List.iter
    (fun (s, expected) ->
      let name = Printf.sprintf "Cgt.Traverse on statement constructor %d" (cgt_stat_tag s) in
      check (name ^ ": parts") (same_parts (CP.stat_parts s) expected);
      let visited, rebuilt = mapped CP.map_stat_parts CP.stat_parts s in
      check (name ^ ": map visits its parts in order") (same_parts visited expected);
      check (name ^ ": map rebuilds every part")
        (List.length (fst rebuilt) = List.length (fst expected)
        && List.length (snd rebuilt) = List.length (snd expected)
        && not (List.exists (fun x -> List.memq x (fst expected)) (fst rebuilt))
        && not (List.exists (fun b -> List.memq b (snd expected)) (snd rebuilt))))
    stats;
  (* A walk reaches every node once, outermost first. *)
  let inner = cleaf () in
  let body = [ C.Stat.If { cond = inner; body = [ C.Stat.Eval { inner with C.Expr.node = C.Expr.Deref inner } ] } ] in
  let order = ref [] in
  CP.walk_stats
    (fun e -> order := `E (cgt_tag e.C.Expr.node) :: !order)
    (fun s -> order := `S (cgt_stat_tag s) :: !order)
    body;
  check "Cgt.Traverse.walk_stats visits every node outermost first"
    (List.rev !order = [ `S 6; `E 0; `S 4; `E 7; `E 0 ])

let run check =
  tst check;
  cgt check
