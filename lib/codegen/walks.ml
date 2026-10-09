(* Each type's walks over the blocks its values own (docs/design/lowering.md
   §9): a copy, an end, a move and an overwrite, emitted for each type
   whose layout lists a position once the program needs them, and the
   type's table of them, which the runtime is handed wherever it is to walk
   a value of the type. Emitted code also vacates a value of the type
   itself. A walk knows its type's positions, their offsets and the tags
   each is under, so it reads each handle and box where it is and calls the
   walks of what they hold directly. Past [deepest] calls it hands a nested
   walk to the runtime's work instead, which runs it from the top, so a
   value nested any number of boxes deep is walked without the machine
   stack growing with it. *)

open Cgt.Nodes

type env = {
  ctx : Llvm.llcontext;
  m : Llvm.llmodule;
  ptr : Llvm.lltype;
  i64 : Llvm.lltype;
  runtime : Cgt.Runtime.fn -> Llvm.llvalue * Llvm.lltype;
}

type walks = {
  copy : Llvm.llvalue;
  end_ : Llvm.llvalue;
  move : Llvm.llvalue;
  overwrite : Llvm.llvalue;
  table : Llvm.llvalue;
}

(* How many walks deep a walk calls the next itself. *)
let deepest = 256

(* A region's heap (runtime/zane_internal.h, which asserts each offset): a
   stack of returned blocks for each size class of 1 to [classes] words,
   then its frontier, the frontier's end, and its count of blocks out. *)
let classes = 16
let frontier = 8 * classes
let frontier_end = frontier + 8
let live = frontier_end + 8

(* A string's or a list's handle: its bytes or elements, its length or
   count, and its room. *)
let length = 8
let room = 16
let line = 64

(* A walk takes the place, what it works with, a number, the work it hands
   walks on to, and its depth (runtime/zane.h). *)
let walk_type env =
  Llvm.function_type (Llvm.void_type env.ctx) [| env.ptr; env.ptr; env.i64; env.ptr; env.i64 |]

(* One walk being built: its builder and its parameters. *)
type fn = {
  env : env;
  f : Llvm.llvalue;
  b : Llvm.llbuilder;
  at : Llvm.llvalue;
  with_ : Llvm.llvalue;
  extra : Llvm.llvalue;
  work : Llvm.llvalue;
  depth : Llvm.llvalue;
}

let int env n = Llvm.const_int env.i64 n

let offset c base n =
  if n = 0 then base
  else Llvm.build_in_bounds_gep (Llvm.i8_type c.env.ctx) base [| int c.env n |] "" c.b

let load c t p = Llvm.build_load t p "" c.b
let store c v p = ignore (Llvm.build_store v p c.b)

let runtime c fn args =
  let f, t = c.env.runtime fn in
  Llvm.build_call t f args "" c.b

let nonzero c v = Llvm.build_icmp Llvm.Icmp.Ne v (Llvm.const_null (Llvm.type_of v)) "" c.b

let memcpy c dst src size =
  let env = c.env in
  let name = "llvm.memcpy.p0.p0.i64" in
  let t =
    Llvm.function_type (Llvm.void_type env.ctx)
      [| env.ptr; env.ptr; env.i64; Llvm.i1_type env.ctx |]
  in
  let f =
    match Llvm.lookup_function name env.m with
    | Some f -> f
    | None -> Llvm.declare_function name t env.m
  in
  ignore (Llvm.build_call t f [| dst; src; size; Llvm.const_int (Llvm.i1_type env.ctx) 0 |] "" c.b)

let block c = Llvm.append_block c.env.ctx "" c.f

(* [body] runs when [cond] holds. *)
let when_ c cond body =
  let yes = block c and after = block c in
  ignore (Llvm.build_cond_br cond yes after c.b);
  Llvm.position_at_end yes c.b;
  body ();
  ignore (Llvm.build_br after c.b);
  Llvm.position_at_end after c.b

let either c cond yes no =
  let y = block c and n = block c and after = block c in
  ignore (Llvm.build_cond_br cond y n c.b);
  Llvm.position_at_end y c.b;
  yes ();
  ignore (Llvm.build_br after c.b);
  Llvm.position_at_end n c.b;
  no ();
  ignore (Llvm.build_br after c.b);
  Llvm.position_at_end after c.b

(* [body] for each index from 0 below [count]. *)
let each c count body =
  let entry = Llvm.builder_at c.env.ctx (Llvm.instr_begin (Llvm.entry_block c.f)) in
  let i = Llvm.build_alloca c.env.i64 "" entry in
  store c (int c.env 0) i;
  let head = block c and step = block c and after = block c in
  ignore (Llvm.build_br head c.b);
  Llvm.position_at_end head c.b;
  let current = load c c.env.i64 i in
  ignore (Llvm.build_cond_br (Llvm.build_icmp Llvm.Icmp.Slt current count "" c.b) step after c.b);
  Llvm.position_at_end step c.b;
  body current;
  store c (Llvm.build_add current (int c.env 1) "" c.b) i;
  ignore (Llvm.build_br head c.b);
  Llvm.position_at_end after c.b

(* Whether a position is there in the value at [base]: every variant tag
   it lies under is live. *)
let present c base (p : Layout.position) =
  let i32 = Llvm.i32_type c.env.ctx in
  List.fold_left
    (fun cond (o, tag) ->
      let live =
        Llvm.build_icmp Llvm.Icmp.Eq (load c i32 (offset c base o)) (Llvm.const_int i32 tag) "" c.b
      in
      match cond with None -> Some live | Some cond -> Some (Llvm.build_and cond live "" c.b))
    None p.tags

let where_present c base p body =
  match present c base p with None -> body () | Some cond -> when_ c cond body

(* A nested value's walk: called here, one deeper, or past [deepest]
   handed on to the work. *)
let visit c walk at with_ extra =
  either c
    (Llvm.build_icmp Llvm.Icmp.Slt c.depth (int c.env deepest) "" c.b)
    (fun () ->
      let next = Llvm.build_add c.depth (int c.env 1) "" c.b in
      ignore (Llvm.build_call (walk_type c.env) walk [| at; with_; extra; c.work; next |] "" c.b))
    (fun () -> ignore (runtime c Cgt.Runtime.Defer [| c.work; walk; at; with_; extra |]))

(* A block of [size] bytes, aligned to a word, in the region a copy works
   with, whose lock the copy holds: the top of its size class's stack, or
   the next bytes at its frontier, or what the runtime finds when neither
   has one. *)
let take c region size =
  let env = c.env in
  let words = max 1 ((size + 7) / 8) in
  if words > classes then runtime c Cgt.Runtime.Alloc_held [| region; int env size; int env 8 |]
  else begin
    let counted () =
      let count = offset c region live in
      store c (Llvm.build_add (load c env.i64 count) (int env 1) "" c.b) count
    in
    let stack = offset c region (8 * (words - 1)) in
    let top = load c env.ptr stack in
    let pop = block c
    and bump = block c
    and fits = block c
    and slow = block c
    and done_ = block c in
    ignore (Llvm.build_cond_br (nonzero c top) pop bump c.b);
    Llvm.position_at_end pop c.b;
    store c (load c env.ptr top) stack;
    counted ();
    ignore (Llvm.build_br done_ c.b);
    Llvm.position_at_end bump c.b;
    let at = load c env.ptr (offset c region frontier) in
    let ends = load c env.ptr (offset c region frontier_end) in
    let left =
      Llvm.build_sub
        (Llvm.build_ptrtoint ends env.i64 "" c.b)
        (Llvm.build_ptrtoint at env.i64 "" c.b)
        "" c.b
    in
    ignore
      (Llvm.build_cond_br
         (Llvm.build_icmp Llvm.Icmp.Sge left (int env (8 * words)) "" c.b)
         fits slow c.b);
    Llvm.position_at_end fits c.b;
    store c (offset c at (8 * words)) (offset c region frontier);
    counted ();
    ignore (Llvm.build_br done_ c.b);
    Llvm.position_at_end slow c.b;
    let found = runtime c Cgt.Runtime.Alloc_held [| region; int env size; int env 8 |] in
    let slow_end = Llvm.insertion_block c.b in
    ignore (Llvm.build_br done_ c.b);
    Llvm.position_at_end done_ c.b;
    Llvm.build_phi [ (top, pop); (at, fits); (found, slow_end) ] "" c.b
  end

(* The runtime's `zane_open`, the innermost scope's record while no other
   thread can reach this thread's context, else null (runtime/arena.c). The
   program and the runtime are linked into one executable, so it is read at
   a fixed offset from the thread's pointer rather than through a call. *)
let zane_open m ptr =
  match Llvm.lookup_global "zane_open" m with
  | Some g -> g
  | None ->
      let g = Llvm.declare_global ptr "zane_open" m in
      Llvm.set_thread_local_mode Llvm.ThreadLocalMode.InitialExec g;
      g

(* A box's block (memory.md §3.6), in the innermost region. Emitted code
   takes it itself, as [take] does, while that region is the runtime's
   [zane_open], which no other thread can reach then; otherwise, and for a
   payload no size class holds, the runtime finds it. *)
let box env f b size align =
  let n = int env in
  let slow () =
    let f, t = env.runtime Cgt.Runtime.Box in
    Llvm.build_call t f [| n size; n align |] "" b
  in
  if align > 8 || (size + 7) / 8 > classes then slow ()
  else begin
    let c =
      let none = Llvm.const_null env.ptr in
      { env; f; b; at = none; with_ = none; extra = n 0; work = none; depth = n 0 }
    in
    let open_ = zane_open env.m env.ptr in
    let region = load c env.ptr open_ in
    let inline = block c and shared = block c and done_ = block c in
    ignore (Llvm.build_cond_br (nonzero c region) inline shared b);
    Llvm.position_at_end inline b;
    let taken = take c region size in
    let inline_end = Llvm.insertion_block b in
    ignore (Llvm.build_br done_ b);
    Llvm.position_at_end shared b;
    let found = slow () in
    ignore (Llvm.build_br done_ b);
    Llvm.position_at_end done_ b;
    Llvm.build_phi [ (taken, inline_end); (found, shared) ] "" b
  end

let zero_handle c h =
  store c (Llvm.const_null c.env.ptr) h;
  store c (int c.env 0) (offset c h length);
  store c (int c.env 0) (offset c h room)

(* ---------------------------------------------------------------------- *)
(* The walks                                                              *)
(* ---------------------------------------------------------------------- *)

(* The program's layouts that list a position, and the walks made of them
   so far: each layout's walks are made the first time something needs
   them, a call or another walk, and built once the program's functions
   are, since a walk may need another, or itself. *)
type known = {
  emitting : env;
  positions : (Layout.t, Layout.position list) Hashtbl.t;
  made : (Layout.t, walks) Hashtbl.t;
  vacates : (Layout.t, Llvm.llvalue) Hashtbl.t;
  mutable unbuilt : (Layout.t * walks) list;
}

let define env name t =
  let f = Llvm.define_function name t env.m in
  Llvm.set_linkage Llvm.Linkage.Internal f;
  f

(* A layout's walks and their table, named for the type it describes
   (docs/design/symbols.md). *)
let walks known l =
  match Hashtbl.find_opt known.made l with
  | Some w -> w
  | None ->
      let env = known.emitting in
      let walk what = define env (l ^ "." ^ what) (walk_type env) in
      let copy = walk "copy"
      and end_ = walk "end"
      and move = walk "move"
      and overwrite = walk "overwrite" in
      let table =
        Llvm.define_global l (Llvm.const_struct env.ctx [| copy; end_; move; overwrite |]) env.m
      in
      Llvm.set_linkage Llvm.Linkage.Private table;
      Llvm.set_global_constant true table;
      let w = { copy; end_; move; overwrite; table } in
      Hashtbl.replace known.made l w;
      known.unbuilt <- (l, w) :: known.unbuilt;
      w

(* The walks of what a list's elements or a box's payload hold, or none
   when they own no blocks. *)
let inner known l = if Hashtbl.mem known.positions l then Some (walks known l) else None

(* Copy: each block the value names is still the original's, so it gets a
   copy of its own in the region the copy works with. *)
let copy known c (p : Layout.position) =
  let env = c.env in
  let h = offset c c.at p.offset in
  match p.kind with
  | Layout.Text ->
      let r = load c env.i64 (offset c h room) in
      when_ c (nonzero c r) (fun () ->
          let n = load c env.i64 (offset c h length) in
          let bytes = runtime c Cgt.Runtime.Alloc_held [| c.with_; n; int env 8 |] in
          memcpy c bytes (load c env.ptr h) n;
          store c bytes h;
          store c n (offset c h room))
  | Layout.List { stride; elements } ->
      let r = load c env.i64 (offset c h room) in
      when_ c (nonzero c r) (fun () ->
          let count = load c env.i64 (offset c h length) in
          let items = runtime c Cgt.Runtime.Alloc_held [| c.with_; r; int env line |] in
          memcpy c items (load c env.ptr h) (Llvm.build_mul count (int env stride) "" c.b);
          store c items h;
          Option.iter
            (fun w ->
              each c count (fun i ->
                  let e =
                    Llvm.build_in_bounds_gep (Llvm.i8_type env.ctx) items
                      [| Llvm.build_mul i (int env stride) "" c.b |]
                      "" c.b
                  in
                  visit c w.copy e c.with_ (int env 0)))
            (inner known elements))
  | Layout.Box { size; payload } ->
      let old = load c env.ptr h in
      when_ c (nonzero c old) (fun () ->
          let fresh = take c c.with_ size in
          memcpy c fresh old (int env size);
          store c fresh h;
          Option.iter (fun w -> visit c w.copy fresh c.with_ (int env 0)) (inner known payload))

(* End: each block the value owns is returned once what lives in it has
   died, and its handle or box names none. A block whose contents are
   handed on is returned by a job handed on before them, so after them. *)
let end_at known c base (p : Layout.position) =
  let env = c.env in
  let h = offset c base p.offset in
  let shallow = Llvm.build_icmp Llvm.Icmp.Slt c.depth (int env deepest) "" c.b in
  let return block size align =
    ignore (runtime c Cgt.Runtime.Free [| block; size; int env align |])
  in
  let defer_return block size align =
    ignore (runtime c Cgt.Runtime.Defer_return [| c.work; block; size; int env align |])
  in
  let next () = Llvm.build_add c.depth (int env 1) "" c.b in
  let call w at =
    ignore
      (Llvm.build_call (walk_type env) w.end_
         [| at; Llvm.const_null env.ptr; int env 0; c.work; next () |]
         "" c.b)
  in
  let defer w at =
    ignore
      (runtime c Cgt.Runtime.Defer [| c.work; w.end_; at; Llvm.const_null env.ptr; int env 0 |])
  in
  (match p.kind with
  | Layout.Text ->
      let r = load c env.i64 (offset c h room) in
      when_ c (nonzero c r) (fun () -> return (load c env.ptr h) r 8);
      zero_handle c h
  | Layout.List { stride; elements } ->
      let r = load c env.i64 (offset c h room) in
      let items = load c env.ptr h in
      (match inner known elements with
      | None -> when_ c (nonzero c r) (fun () -> return items r line)
      | Some w ->
          let count = load c env.i64 (offset c h length) in
          let element i =
            Llvm.build_in_bounds_gep (Llvm.i8_type env.ctx) items
              [| Llvm.build_mul i (int env stride) "" c.b |]
              "" c.b
          in
          either c shallow
            (fun () ->
              each c count (fun i -> call w (element i));
              when_ c (nonzero c r) (fun () -> return items r line))
            (fun () ->
              when_ c (nonzero c r) (fun () -> defer_return items r line);
              each c count (fun i -> defer w (element i))));
      zero_handle c h
  | Layout.Box { size; payload } ->
      let old = load c env.ptr h in
      when_ c (nonzero c old) (fun () ->
          match inner known payload with
          | None -> return old (int env size) 8
          | Some w ->
              either c shallow
                (fun () ->
                  call w old;
                  return old (int env size) 8)
                (fun () ->
                  defer_return old (int env size) 8;
                  defer w old));
      store c (Llvm.const_null env.ptr) h);
  ()

(* Move: each block the value owns that must move into the region the move
   works with goes into an equal block there, and the old one is returned
   (runtime/value.c, `zane_leaves`); what lives in it moves in turn. *)
let move known c (p : Layout.position) =
  let env = c.env in
  let h = offset c c.at p.offset in
  let leaves block = nonzero c (runtime c Cgt.Runtime.Leaves [| block; c.with_; c.extra |]) in
  let relocate old size align copied =
    let fresh = runtime c Cgt.Runtime.Alloc [| c.with_; size; int env align |] in
    memcpy c fresh old copied;
    ignore (runtime c Cgt.Runtime.Free [| old; size; int env align |]);
    store c fresh h;
    fresh
  in
  match p.kind with
  | Layout.Text ->
      let r = load c env.i64 (offset c h room) in
      when_ c (nonzero c r) (fun () ->
          let old = load c env.ptr h in
          when_ c (leaves old) (fun () ->
              ignore (relocate old r 8 (load c env.i64 (offset c h length)))))
  | Layout.List { stride; elements } ->
      let r = load c env.i64 (offset c h room) in
      when_ c (nonzero c r) (fun () ->
          let old = load c env.ptr h in
          when_ c (leaves old) (fun () ->
              let count = load c env.i64 (offset c h length) in
              let items = relocate old r line (Llvm.build_mul count (int env stride) "" c.b) in
              Option.iter
                (fun w ->
                  each c count (fun i ->
                      let e =
                        Llvm.build_in_bounds_gep (Llvm.i8_type env.ctx) items
                          [| Llvm.build_mul i (int env stride) "" c.b |]
                          "" c.b
                      in
                      visit c w.move e c.with_ c.extra))
                (inner known elements)))
  | Layout.Box { size; payload } ->
      let old = load c env.ptr h in
      when_ c (nonzero c old) (fun () ->
          when_ c (leaves old) (fun () ->
              let fresh = relocate old (int env size) 8 (int env size) in
              Option.iter (fun w -> visit c w.move fresh c.with_ c.extra) (inner known payload)))

(* Overwrite (runtime/value.c, `zane_overwrite`): the place hands on its
   arrival first, so it arrives after everything below it. A box present
   in both the occupant and the replacement keeps its block, and the
   replacement's payload is written into it, recursively; everything else
   the occupant owns ends. Then the replacement's bytes are written. *)
let overwrite known self c (ps : Layout.position list) =
  let env = c.env in
  let region = runtime c Cgt.Runtime.Region_at [| c.at |] in
  ignore (runtime c Cgt.Runtime.Defer [| c.work; self.move; c.at; region; int env 0 |]);
  let entry = Llvm.builder_at env.ctx (Llvm.instr_begin (Llvm.entry_block c.f)) in
  let kept =
    List.map
      (fun (p : Layout.position) ->
        match p.kind with
        | Layout.Box _ ->
            let k = Llvm.build_alloca env.ptr "" entry in
            store c (Llvm.const_null env.ptr) k;
            Some k
        | _ -> None)
      ps
  in
  List.iter2
    (fun (p : Layout.position) k ->
      where_present c c.at p (fun () ->
          match k with
          | None -> end_at known c c.at p
          | Some k ->
              let old = load c env.ptr (offset c c.at p.offset) in
              let both =
                match present c c.with_ p with
                | None -> nonzero c (load c env.ptr (offset c c.with_ p.offset))
                | Some there ->
                    (* The replacement's box is read only where it is there. *)
                    let check = block c and after = block c in
                    let from = Llvm.insertion_block c.b in
                    ignore (Llvm.build_cond_br there check after c.b);
                    Llvm.position_at_end check c.b;
                    let named = nonzero c (load c env.ptr (offset c c.with_ p.offset)) in
                    let checked = Llvm.insertion_block c.b in
                    ignore (Llvm.build_br after c.b);
                    Llvm.position_at_end after c.b;
                    Llvm.build_phi
                      [ (Llvm.const_int (Llvm.i1_type env.ctx) 0, from); (named, checked) ]
                      "" c.b
              in
              either c
                (Llvm.build_and (nonzero c old) both "" c.b)
                (fun () -> store c old k)
                (fun () -> end_at known c c.at p)))
    ps kept;
  memcpy c c.at c.with_ c.extra;
  List.iter2
    (fun (p : Layout.position) k ->
      match (p.kind, k) with
      | Layout.Box { size; payload }, Some k ->
          let old = load c env.ptr k in
          when_ c (nonzero c old) (fun () ->
              let h = offset c c.at p.offset in
              let incoming = load c env.ptr h in
              store c old h;
              let n = int env size in
              let return () = ignore (runtime c Cgt.Runtime.Free [| incoming; n; int env 8 |]) in
              match inner known payload with
              | None ->
                  memcpy c old incoming n;
                  return ()
              | Some w ->
                  either c
                    (Llvm.build_icmp Llvm.Icmp.Slt c.depth (int env deepest) "" c.b)
                    (fun () ->
                      let next = Llvm.build_add c.depth (int env 1) "" c.b in
                      ignore
                        (Llvm.build_call (walk_type env) w.overwrite
                           [| old; incoming; n; c.work; next |]
                           "" c.b);
                      return ())
                    (fun () ->
                      ignore
                        (runtime c Cgt.Runtime.Defer_return [| c.work; incoming; n; int env 8 |]);
                      ignore
                        (runtime c Cgt.Runtime.Defer [| c.work; w.overwrite; old; incoming; n |])))
      | _ -> ())
    ps kept

(* Vacate: an owner moved out of its slot, and its blocks left with it
   (lifetimes.md §1.6), so the slot names none. *)
let vacate c (p : Layout.position) =
  let h = offset c c.at p.offset in
  match p.kind with
  | Layout.Text | Layout.List _ -> zero_handle c h
  | Layout.Box _ -> store c (Llvm.const_null c.env.ptr) h

(* ---------------------------------------------------------------------- *)
(* Emitting them                                                          *)
(* ---------------------------------------------------------------------- *)

let body env f build =
  let b = Llvm.builder_at_end env.ctx (Llvm.entry_block f) in
  let c =
    {
      env;
      f;
      b;
      at = Llvm.param f 0;
      with_ = Llvm.param f 1;
      extra = Llvm.param f 2;
      work = Llvm.param f 3;
      depth = Llvm.param f 4;
    }
  in
  build c;
  ignore (Llvm.build_ret_void b)

let create env (named : (Layout.t * Layout.position list) list) =
  let positions = Hashtbl.create 16 in
  List.iter (fun (l, ps) -> if ps <> [] then Hashtbl.replace positions l ps) named;
  { emitting = env; positions; made = Hashtbl.create 16; vacates = Hashtbl.create 8; unbuilt = [] }

(* Whether a layout lists a position, and so has walks. *)
let listed known l = Hashtbl.mem known.positions l

(* A layout's table of walks, or none when it lists nothing. *)
let table known l =
  if listed known l then (walks known l).table else Llvm.const_null known.emitting.ptr

(* The function that vacates a value of the layout, if it lists anything. *)
let vacater known l =
  match (Hashtbl.find_opt known.vacates l, Hashtbl.find_opt known.positions l) with
  | Some f, _ -> Some f
  | None, None -> None
  | None, Some ps ->
      let env = known.emitting in
      let f =
        define env (l ^ ".vacate") (Llvm.function_type (Llvm.void_type env.ctx) [| env.ptr |])
      in
      let b = Llvm.builder_at_end env.ctx (Llvm.entry_block f) in
      let c =
        {
          env;
          f;
          b;
          at = Llvm.param f 0;
          with_ = Llvm.const_null env.ptr;
          extra = int env 0;
          work = Llvm.const_null env.ptr;
          depth = int env 0;
        }
      in
      List.iter (fun p -> where_present c c.at p (fun () -> vacate c p)) ps;
      ignore (Llvm.build_ret_void b);
      Hashtbl.replace known.vacates l f;
      Some f

(* Every walk made and not yet built, built, with the ones they make. *)
let rec finish known =
  match known.unbuilt with
  | [] -> ()
  | (l, w) :: rest ->
      known.unbuilt <- rest;
      let env = known.emitting in
      let ps = Hashtbl.find known.positions l in
      let all build c = List.iter (fun p -> where_present c c.at p (fun () -> build c p)) ps in
      body env w.copy (all (copy known));
      body env w.end_ (all (fun c p -> end_at known c c.at p));
      body env w.move (all (move known));
      body env w.overwrite (fun c -> overwrite known w c ps);
      finish known
