(* What codegen and the optimizer determine about a loop's lists: the pushes
   whose room is made before the loop, the functions that cannot change a
   list's count, and the lists read once before the loop. *)

open Support

(* A loop's lone push onto a list has its room made before the loop
   (Loop_shapes.looped_pushes), unless another call in the loop may grow
   the list through a reference, the pushed value's own call included. *)
let looped_pushes () =
  let module C = Cgt.Nodes in
  let e node ty = { C.Expr.node; ty } in
  let push =
    C.Stat.Let
      {
        id = 11;
        value =
          e
            (C.Expr.Runtime
               { fn = Cgt.Runtime.List_push; args = [ e (C.Expr.Address 1) C.Ty.Ptr; e (C.Expr.Int 8L) C.Ty.I64 ] })
            C.Ty.Ptr;
      }
  in
  let grow = C.Stat.Let { id = 10; value = e (C.Expr.Call { fn = "app$grow"; args = [ e (C.Expr.Local 2) C.Ty.Ptr ] }) C.Ty.I64 } in
  let expand body = C.Stat.Eval (e (C.Expr.Expand { label = 20; body; result = None }) C.Ty.Void) in
  let on = Sys.getenv_opt "ZANE_LOOP_PUSHES" <> Some "0" in
  check "a loop's lone push has its room made ahead, unless switched off"
    (Codegen__Loop_shapes.looped_pushes [ expand [ push ] ] = if on then [ (1, 8L) ] else []);
  check "not when the pushed value's call may grow a list"
    (Codegen__Loop_shapes.looped_pushes [ expand [ grow; push ] ] = []);
  (* A written-out push ends by leaving its own expansion (Loop_pushes),
     which leaves nothing around the loop. *)
  check "a push that leaves its own expansion has its room made ahead, unless switched off"
    (Codegen__Loop_shapes.looped_pushes [ expand [ push; C.Stat.Leave 20 ] ] = if on then [ (1, 8L) ] else []);
  check "not when the loop leaves an expansion around it"
    (Codegen__Loop_shapes.looped_pushes [ expand [ push; C.Stat.Leave 20 ]; C.Stat.Leave 30 ] = []);
  check "not when the loop may return"
    (Codegen__Loop_shapes.looped_pushes [ expand [ push ]; C.Stat.Return (e C.Expr.Unit C.Ty.Void) ] = [])

(* A function cannot change a list's count when nothing it runs can
   (Loop_pushes.pure). An imported function's body is another object's, so
   its empty body proves nothing, and it is never taken to be one; nor is a
   function that calls it. *)
let list_pure () =
  let module C = Cgt.Nodes in
  let e node ty = { C.Expr.node; ty } in
  let func symbol linkage body =
    { C.Func.symbol; linkage; params = []; places = []; ret = C.Ty.Void; body; values = [] }
  in
  let call fn = C.Stat.Eval (e (C.Expr.Call { fn; args = [] }) C.Ty.Void) in
  let program funcs =
    { C.Program.funcs; entry = None; comptime = []; layouts = []; globals = []; foreign = []; callbacks = []; exclusive = true }
  in
  Optimize__Loop_pushes.pure
    (program
       [
         func "app$quiet" C.Linkage.Local [];
         func "dep$grow" C.Linkage.Imported [];
         func "app$caller" C.Linkage.Local [ call "dep$grow" ];
         func "app$calm" C.Linkage.Local [ call "app$quiet" ];
       ]);
  let pure fn = Hashtbl.mem Cgt.List_pure.functions fn in
  check "a function that changes no list is list-pure" (pure "app$quiet" && pure "app$calm");
  check "an imported function is not list-pure" (not (pure "dep$grow"));
  check "nor is one that calls it" (not (pure "app$caller"));
  (* C cannot call back into a whole program that gives it no function
     value and holds every function's body (Cgt.List_pure.c_stays). *)
  check "C may call back into a program that imports a function" (not !Cgt.List_pure.c_stays);
  let whole = func "app$quiet" C.Linkage.Local [] in
  Optimize__Loop_pushes.pure { (program [ whole ]) with C.Program.entry = Some "app$main" };
  check "but not into a whole program that gives it no function value" !Cgt.List_pure.c_stays;
  Optimize__Loop_pushes.pure (program [ whole ]);
  check "a library may be called back" (not !Cgt.List_pure.c_stays);
  Cgt.List_pure.c_stays := false;
  Hashtbl.reset Cgt.List_pure.functions;
  Hashtbl.reset Cgt.List_pure.handles

(* A loop's lists are read once before it when nothing in it can change
   their handles (Loop_shapes.invariant_lists): it may push onto a list
   only its function reaches, call a function that changes no handle, and
   call into C when C cannot call back, and an element of a list read
   before the loop, at an index the loop does not change, is read before it
   too. *)
let invariant_lists () =
  let module C = Cgt.Nodes in
  let e node ty = { C.Expr.node; ty } in
  let int n = e (C.Expr.Int n) C.Ty.I64 in
  let at list index stride = e (C.Expr.Runtime { fn = Cgt.Runtime.List_at; args = [ list; index; int stride ] }) C.Ty.Ptr in
  let read list = C.Stat.Let { id = 40; value = e (C.Expr.Deref (at list (e (C.Expr.Local 41) C.Ty.I64) 8L)) C.Ty.I64 } in
  let xs = e (C.Expr.Local 1) C.Ty.Ptr and queue = e (C.Expr.Address 5) C.Ty.Ptr in
  let push list =
    C.Stat.Let { id = 42; value = e (C.Expr.Runtime { fn = Cgt.Runtime.List_push; args = [ list; int 8L ] }) C.Ty.Ptr }
  in
  let call fn = C.Stat.Eval (e (C.Expr.Call { fn; args = [] }) C.Ty.Void) in
  let foreign = C.Stat.Eval (e (C.Expr.Foreign_call { thunk = "c$put"; args = [] }) C.Ty.Void) in
  let lists ?(own = fun x -> x = 5) body = fst (Codegen__Loop_shapes.invariant_lists ~own body) in
  let on = Sys.getenv_opt "ZANE_HOIST_HANDLES" <> Some "0" in
  let hoisted = if on then [ xs ] else [] in
  check "a loop that only reads a list reads it once before" (lists [ read xs ] = hoisted);
  check "and one that also pushes onto a list only its function reaches" (lists [ read xs; push queue ] = hoisted);
  check "not one that pushes onto a list another address may reach" (lists ~own:(fun _ -> false) [ read xs; push queue ] = []);
  check "nor the list it pushes onto" (lists [ read xs; read queue; push queue ] = hoisted);
  check "not one that calls a function that may change a handle" (lists [ read xs; call "app$grow" ] = []);
  Hashtbl.replace Cgt.List_pure.handles "app$calm" ();
  check "but one that calls a function that cannot" (lists [ read xs; call "app$calm" ] = hoisted);
  check "not one that calls into C that may call back" (lists [ read xs; foreign ] = []);
  check "and C that may call back may grow a list" (Codegen__Loop_shapes.may_grow foreign);
  Cgt.List_pure.c_stays := true;
  check "but one that calls into C that cannot" (lists [ read xs; foreign ] = hoisted);
  check "and C that cannot grows no list" (not (Codegen__Loop_shapes.may_grow foreign));
  let row index = at xs index 16L in
  let rows = e (C.Expr.Local 43) C.Ty.I64 in
  check "in a loop that pushes, an element at an index the loop does not change is read after its list"
    (lists [ read (row rows); push queue ] = if on then [ xs; row rows ] else []);
  check "not one at an index the loop changes"
    (lists [ C.Stat.Let { id = 43; value = int 2L }; read (row rows); push queue ] = if on then [ xs ] else []);
  check "nor in a loop that neither pushes nor calls, which LLVM reads once by itself"
    (lists [ read (row rows) ] = hoisted);
  let cell index = at (row rows) index 8L in
  let cols = e (C.Expr.Local 44) C.Ty.I64 in
  check "an element of an element after the element it is in, whatever order they are met in"
    (lists [ read (cell cols); read (row rows); push queue ] = if on then [ xs; row rows; cell cols ] else []);
  let member = e (C.Expr.Offset { base = row rows; within = C.Ty.Struct [ C.Ty.I64; C.Ty.Ptr ]; path = [ 1 ] }) C.Ty.Ptr in
  check "and a list in a member of an element after its list"
    (lists [ read member; push queue ] = if on then [ xs; member ] else []);
  let calm args = C.Stat.Eval (e (C.Expr.Call { fn = "app$calm"; args }) C.Ty.Void) in
  check "not an element at an index whose slot a call may write"
    (lists [ read (row rows); calm [ e (C.Expr.Address 43) C.Ty.Ptr ] ] = if on then [ xs ] else []);
  check "but one at an index a call only reads"
    (lists [ read (row rows); calm [ e (C.Expr.Deref (e (C.Expr.Address 43) C.Ty.Ptr)) C.Ty.I64 ] ]
    = if on then [ xs; row rows ] else []);
  let payload = e (C.Expr.Offset { base = row rows; within = C.Ty.Sum [ C.Ty.I64; C.Ty.Struct [ C.Ty.Ptr ] ]; path = [ 1 ] }) C.Ty.Ptr in
  check "not a list in a variant's payload in an element, which may be another case's bytes"
    (lists [ read payload; push queue ] = if on then [ xs ] else []);
  Cgt.List_pure.c_stays := false;
  Hashtbl.reset Cgt.List_pure.handles

(* A loop is a search that IRCE is kept out of ([searches]) when it can
   leave early, holds no loop, and reads an element at an index that moves
   by a constant each time round (Loop_shapes.scans): a quicksort's
   partition scan, not a heap's sift, whose index halves or jumps. *)
let searches () =
  let module C = Cgt.Nodes in
  let e node ty = { C.Expr.node; ty } in
  let int n = e (C.Expr.Int n) C.Ty.I64 in
  let local x = e (C.Expr.Local x) C.Ty.I64 in
  let read index =
    C.Stat.Let
      { id = 40; value = e (C.Expr.Deref (e (C.Expr.Runtime { fn = Cgt.Runtime.List_at; args = [ local 1; index; int 8L ] }) C.Ty.Ptr)) C.Ty.I64 }
  in
  let set x value = C.Stat.Assign { place = { C.Expr.local = x; deref = false; ty = C.Ty.I64; path = [] }; value } in
  let add a b = e (C.Expr.Binary { op = C.Expr.Add; left = a; right = b }) C.Ty.I64 in
  let up = set 5 (add (local 5) (int 1L)) and down = set 5 (add (local 5) (e (C.Expr.Flip (int 1L)) C.Ty.I64)) in
  let leave = C.Stat.If { cond = e (C.Expr.Bool true) C.Ty.I1; body = [ C.Stat.Return (local 5) ] } in
  (* A `to` loop's body ends with its counter's step. *)
  let count = set 7 (add (local 7) (int 1L)) in
  let stepped body = Codegen__Loop_shapes.scans (body @ [ count ])
  and searches body = Codegen__Loop_shapes.searches (body @ [ count ]) in
  check "an index a scan steps up by one moves by a constant" (stepped [ read (local 5); up ]);
  check "and one it steps down" (stepped [ read (local 5); down ]);
  check "and an index a constant past it" (stepped [ read (add (local 5) (int 1L)); up ]);
  check "with the constant on either side"
    (stepped [ read (add (int 1L) (local 5)); set 5 (add (int 1L) (local 5)) ]);
  check "not one the loop halves"
    (not (stepped [ read (local 5); set 5 (e (C.Expr.Binary { op = C.Expr.Div; left = local 5; right = int 2L }) C.Ty.I64) ]));
  check "nor one it sets to another local" (not (stepped [ read (local 5); set 5 (local 6) ]));
  check "nor one it assigns twice" (not (stepped [ read (local 5); up; up ]));
  check "nor the counter, which walks the range its count names"
    (not (stepped [ read (local 7); leave ]));
  check "but an index it steps beside the counter" (stepped [ read (local 5); leave; up ]);
  (* a1 = a0 + a0, a2 = a1 + a1, ..., i = i + a30: a recogniser that
     substitutes both sides of every sum expands 2^30 nodes. *)
  let doublings =
    C.Stat.Let { id = 100; value = local 6 }
    :: List.init 30 (fun k -> C.Stat.Let { id = 101 + k; value = add (local (100 + k)) (local (100 + k)) })
  in
  check "a step through a chain of sums is turned down at once"
    (not (stepped ((read (local 5) :: doublings) @ [ set 5 (add (local 5) (local 130)) ])));
  check "a scan that returns is a search" (searches [ read (local 5); leave; up ]);
  check "not one that never leaves" (not (searches [ read (local 5); up ]));
  check "nor one that holds a loop"
    (not (searches [ read (local 5); leave; C.Stat.Repeat { count = int 4L; body = [] }; up ]));
  check "nor one whose index jumps while it reads its counter"
    (not (searches [ read (local 5); read (local 7); leave; set 5 (local 6) ]));
  check "a scan whose counter only steps is a search however its index moves"
    (searches [ read (local 5); leave; set 5 (local 6) ]);
  check "but not a loop whose counter only steps and that reads no element"
    (not (searches [ leave; set 5 (local 6) ]))

(* A recursion's base case is made at its self-calls (Leaf_peel) only in a
   function whose frame is small: the leaf inlined there brings its own
   copy of the frame's allocations to each level of the recursion. *)
let leaf_peel () =
  let peeled bytes =
    let ctx = Llvm.create_context () in
    let ir =
      Printf.sprintf
        {|define i64 @"app$depth"(i64 %%n) {
entry:
  %%room = alloca [%d x i8], align 8
  %%done = icmp eq i64 %%n, 0
  br i1 %%done, label %%base, label %%deep
base:
  ret i64 0
deep:
  store volatile i8 1, ptr %%room, align 8
  %%less = sub i64 %%n, 1
  %%below = call i64 @"app$depth"(i64 %%less)
  %%seen = load volatile i8, ptr %%room, align 8
  %%wide = zext i8 %%seen to i64
  %%sum = add i64 %%below, %%wide
  ret i64 %%sum
}
|}
        bytes
    in
    let m = Llvm_irreader.parse_ir ctx (Llvm.MemoryBuffer.of_string ir) in
    let f = Option.get (Llvm.lookup_function "app$depth" m) in
    let made = Codegen__Leaf_peel.func f Codegen__Leaf_peel.budget Codegen__Leaf_peel.frame in
    Llvm.dispose_module m;
    Llvm.dispose_context ctx;
    made = 1
  in
  check "a recursion with a small frame has its base case made at its self-calls" (peeled 64);
  check "one whose frame passes the bound is left"
    (not (peeled (Codegen__Leaf_peel.frame + 8)))

(* Which loops strip mining cuts into runs (Strip.fits): one whose body
   indexes a small array through `bitAnd` and ends with its counter's step
   by one, however lowering wrapped the step. *)
let strip_steps () =
  let module C = Cgt.Nodes in
  let e node ty = { C.Expr.node; ty } in
  let int n = e (C.Expr.Int n) C.Ty.I64 in
  let local x = e (C.Expr.Local x) C.Ty.I64 in
  let add a b = e (C.Expr.Binary { op = C.Expr.Add; left = a; right = b }) C.Ty.I64 in
  let set x value = C.Stat.Assign { place = { C.Expr.local = x; deref = false; ty = C.Ty.I64; path = [] }; value } in
  let lane = e (C.Expr.Math { fn = Cgt.Math.Bit_and; args = [ local 5; int 7L ] }) C.Ty.I64 in
  let read =
    C.Stat.Let
      { id = 40; value = e (C.Expr.Runtime { fn = Cgt.Runtime.Array_at; args = [ local 1; lane; int 8L; int 4L ] }) C.Ty.Ptr }
  in
  (* core's `Int +`: an expansion that assigns its result, then leaves. *)
  let wrapped ?(label = 60) ?(extra = []) by =
    e
      (C.Expr.Expand
         { label = 60; result = Some 61;
           body = [ C.Stat.Let { id = 62; value = int by }; set 61 (add (local 5) (local 62)) ] @ extra @ [ C.Stat.Leave label ] })
      C.Ty.I64
  in
  let fits step = Optimize__Strip.fits (Hashtbl.create 1) [ read; set 5 step ] <> None in
  check "a counter stepped by one fits" (fits (add (local 5) (int 1L)));
  check "and one stepped through an operator's expansion" (fits (wrapped 1L));
  check "not one that expansion steps by two" (not (fits (wrapped 2L)));
  check "nor one whose expansion leaves another's label" (not (fits (wrapped ~label:59 1L)));
  check "nor one whose expansion assigns its result twice"
    (not (fits (wrapped ~extra:[ set 61 (add (local 5) (int 2L)) ] 1L)));
  (* a1 = a0 + a0, ..., a30 = a29 + a29, then x + a30: read once per let,
     not 2^30 times. *)
  let doublings =
    C.Stat.Let { id = 100; value = local 6 }
    :: List.init 30 (fun k -> C.Stat.Let { id = 101 + k; value = add (local (100 + k)) (local (100 + k)) })
  in
  let doubled =
    e (C.Expr.Expand { label = 60; result = Some 61; body = doublings @ [ set 61 (add (local 5) (local 130)); C.Stat.Leave 60 ] }) C.Ty.I64
  in
  check "nor one stepped by a sum of lets, read in linear time" (not (fits doubled))
