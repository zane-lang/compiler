(* The CGT run at compile time (docs/design/optimization.md O5). Each node
   means here what codegen makes it mean in lib/codegen/emit.ml, and each
   runtime function what runtime/ does, except where the bytes of a value
   live: arenas, regions and the blocks that move between them are nothing
   here, since no program can tell one placement from another
   (docs/design/lowering.md §9).

   A run stops, with [Value.Stop], at anything it cannot know: an input, a
   local the fold has no value for, a function with no body here, a division
   by zero or an index out of range (which must stop the program when it
   runs), or a budget spent. *)

open Cgt.Nodes
open Value

(* What a run did that the running program must still do, in order (O4). *)
type output = Print of string | Set_threads of int64 | Set_threads_auto

(* A package constant's two variables (docs/design/lowering.md L16), and its
   value once it is known to fold. *)
type constant = { maker : string; state : string; value : string; mutable known : const option }

type program = {
  funcs : (string, Func.t) Hashtbl.t;
  layouts : (Layout.t, Layout.position list) Hashtbl.t;
  globals : (string, Global.t) Hashtbl.t;
  (* By the symbol of each of the constant's variables. *)
  constants : (string, constant) Hashtbl.t;
  (* A call's result and what it output, by the function and its
     arguments (O6). *)
  memo : (const * output list) Key.t;
  (* The steps every fold of the program may take together, so that many
     calls that each run out of budget cannot make a build slow. *)
  mutable left : int;
}

(* The steps one fold may take, all the folds of a program, and how deep
   calls may go (O6). *)
let budget = 1_000_000
let total = 50_000_000
let max_depth = 2_000

type run = {
  prog : program;
  mutable steps : int;
  mutable depth : int;
  mutable outputs : output list;
  cells : (string, cell) Hashtbl.t;
  (* What each variable held when the run first read it, and that as a
     constant: a store into a member writes the value in place. *)
  initial : (string, v * const option) Hashtbl.t;
  (* The constant this run is making, when it is making one (Constants). *)
  making : string option;
}

(* The locals of one call. The function being folded has [outer]: the value
   the fold knows a local of it holds, read the first time it is needed. *)
type frame = { locals : (int, cell) Hashtbl.t; outer : (int -> (const * Ty.t) option) option }

exception Left of int
exception Returned of v

let start ?making prog =
  {
    prog;
    steps = budget;
    depth = 0;
    outputs = [];
    cells = Hashtbl.create 8;
    initial = Hashtbl.create 8;
    making;
  }

(* Whether the run wrote a variable of the program, which folding the code
   that did it would lose: only a run that makes a constant may. *)
let wrote_globals run =
  Hashtbl.fold
    (fun g (c : cell) w ->
      w
      ||
      let v, held = Hashtbl.find run.initial g in
      c.value != v
      ||
      match (export c.value, held) with
      | Some now, Some held -> not (same now held)
      | None, None -> false
      | _ -> true)
    run.cells false

let spend run n =
  run.steps <- run.steps - n;
  run.prog.left <- run.prog.left - n;
  if run.steps <= 0 || run.prog.left <= 0 then stop "the step budget ran out"

let tick run = spend run 1

(* Work that grows with the size of what it makes or copies costs a step for
   each 64 bytes, charged before the work is done, so a few steps cannot
   build a value of any size. *)
let bytes run n = if n >= 64 then spend run (n / 64)
let sized run t = bytes run (fst (Ty.size_align t))

(* ---------------------------------------------------------------------- *)
(* Places                                                                 *)
(* ---------------------------------------------------------------------- *)

let local fr id =
  match Hashtbl.find_opt fr.locals id with
  | Some c -> c
  | None -> (
      match Option.bind fr.outer (fun known -> known id) with
      | Some (c, ty) ->
          let c = cell ~origin:(Outer id) ty (import c) in
          Hashtbl.replace fr.locals id c;
          c
      | None -> stop "a local whose value is not known")

let bind fr id ty v = Hashtbl.replace fr.locals id (cell ty v)

(* A variable of the program: a constant's value and state, or a program
   value such as the console, which holds nothing a program reads. *)
let global run g =
  match Hashtbl.find_opt run.cells g with
  | Some c -> c
  | None ->
      let ty = match Hashtbl.find_opt run.prog.globals g with Some g -> g.Global.ty | None -> Ty.I64 in
      (* A constant that does not fold has no value here: its state stops a
         read of it, and its value holds nothing until the run that makes
         it stores one. *)
      let value =
        match Hashtbl.find_opt run.prog.constants g with
        | Some k when g = k.state -> (
            match (k.known, run.making) with
            | Some _, _ -> VInt (-1L)
            | None, Some m when m = k.state -> VInt 0L
            | None, _ -> VNull)
        | Some { known = Some c; _ } -> import c
        | Some { known = None; _ } -> VNull
        | None -> zero ty
      in
      let c = cell ~origin:(Global g) ty value in
      Hashtbl.replace run.cells g c;
      Hashtbl.replace run.initial g (value, export value);
      c

let ptr_of = function VPtr p -> p | _ -> stop "an address that names nothing"

let int_of = function
  | VInt i -> i
  | _ -> stop "an integer that is not one"

let bool_of = function VBool b -> b | _ -> stop "a condition that is not a Bool"
let text_of = function VText s -> s | _ -> stop "a string that is not one"

(* An address down [path] from [p], through a value of type [within]: a
   sum's case whose payload is nothing takes no step (emit.ml). *)
let offset (p : ptr) within path =
  let steps, _ =
    List.fold_left
      (fun (steps, t) i ->
        match t with
        | Ty.Struct ts -> (Member i :: steps, List.nth ts i)
        | Ty.Sum ts when List.nth ts i = Ty.Void -> (steps, Ty.Void)
        | Ty.Sum ts -> (Payload i :: steps, List.nth ts i)
        | _ -> stop "an offset through something not a struct")
      ([], within) path
  in
  { p with path = p.path @ List.rev steps }

(* ---------------------------------------------------------------------- *)
(* Arithmetic, as emit.ml's [binary] and [divide]                         *)
(* ---------------------------------------------------------------------- *)

(* A NaN's sign and payload are the host's, and no program can tell one NaN
   from another, so every NaN folds to the same one: the same source folds
   the same way on any machine (O6). *)
let canonical f = if Float.is_nan f then Int64.float_of_bits 0x7FF8_0000_0000_0000L else f

let binary (op : Expr.binop) (t : Ty.t) l r =
  match (t, op, l, r) with
  | (Ty.I64 | Ty.I32), Expr.Add, VInt a, VInt b -> VInt (int t (Int64.add a b))
  | (Ty.I64 | Ty.I32), Expr.Mul, VInt a, VInt b -> VInt (int t (Int64.mul a b))
  | (Ty.I64 | Ty.I32), Expr.Div, VInt _, VInt 0L -> stop "a division by zero"
  (* The one quotient an integer cannot hold wraps, as [+] and [*] do. *)
  | (Ty.I64 | Ty.I32), Expr.Div, VInt a, VInt -1L -> VInt (int t (Int64.neg a))
  | (Ty.I64 | Ty.I32), Expr.Div, VInt a, VInt b -> VInt (int t (Int64.div a b))
  | (Ty.I64 | Ty.I32), Expr.Eq, VInt a, VInt b -> VBool (Int64.equal a b)
  | (Ty.I64 | Ty.I32), Expr.Less, VInt a, VInt b -> VBool (Int64.compare a b < 0)
  | Ty.F64, Expr.Add, VFloat a, VFloat b -> VFloat (canonical (a +. b))
  | Ty.F64, Expr.Mul, VFloat a, VFloat b -> VFloat (canonical (a *. b))
  | Ty.F64, Expr.Div, VFloat a, VFloat b -> VFloat (canonical (a /. b))
  (* Ordered comparisons: a NaN is neither equal to nor less than anything. *)
  | Ty.F64, Expr.Eq, VFloat a, VFloat b -> VBool (a = b)
  | Ty.F64, Expr.Less, VFloat a, VFloat b -> VBool (a < b)
  | Ty.I1, Expr.Add, VBool a, VBool b -> VBool (a || b)
  | Ty.I1, Expr.Mul, VBool a, VBool b -> VBool (a && b)
  | Ty.I1, Expr.Eq, VBool a, VBool b -> VBool (a = b)
  | _ -> stop "an operator on operands it has no meaning for"

let flip (t : Ty.t) v =
  match (t, v) with
  | (Ty.I64 | Ty.I32), VInt a -> VInt (int t (Int64.neg a))
  | Ty.F64, VFloat a -> VFloat (canonical (Float.neg a))
  | Ty.I1, VBool a -> VBool (not a)
  | _ -> stop "`~` on a value it does not flip"

(* ---------------------------------------------------------------------- *)
(* Expressions and statements                                             *)
(* ---------------------------------------------------------------------- *)

let rec expr run fr (e : Expr.t) : v =
  tick run;
  match e.Expr.node with
  | Expr.Int i -> VInt (int e.Expr.ty i)
  | Expr.Float f -> VFloat f
  | Expr.Bool b -> VBool b
  | Expr.Text s -> VText s
  | Expr.Unit -> VUnit
  (* A read is a copy: the local keeps what it holds whatever is done with
     what was read. *)
  | Expr.Local id ->
      sized run e.Expr.ty;
      own (local fr id).value
  | Expr.Address id -> at (local fr id)
  | Expr.Deref p | Expr.Snapshot p -> (
      let p = expr run fr p in
      match e.Expr.ty with
      | Ty.Void -> VUnit
      (* An address read out of a place is lent, though the place may hold
         it as a box: what owns a box is the value the box is in. *)
      | Ty.Ptr -> ( match load (ptr_of p) with VPtr q -> VPtr { q with owned = false } | v -> v)
      | t ->
          sized run t;
          load (ptr_of p))
  | Expr.Call { fn; args } ->
      let args = List.map (expr run fr) args in
      call run fn args
  | Expr.Call_value { fn; args } -> (
      let f = expr run fr fn in
      let args = List.map (expr run fr) args in
      match f with VFunc s -> call run s args | _ -> stop "a call through no function")
  | Expr.Runtime { fn; args } ->
      let args = List.map (expr run fr) args in
      runtime run fn args
  | Expr.Binary { op; left; right } ->
      (* The left operand runs first. *)
      let l = expr run fr left in
      let r = expr run fr right in
      binary op left.Expr.ty l r
  | Expr.Flip value -> flip value.Expr.ty (expr run fr value)
  | Expr.Expand { label; body; result } -> (
      sized run e.Expr.ty;
      Option.iter (fun id -> bind fr id e.Expr.ty (zero e.Expr.ty)) result;
      (try stats run fr body with Left l when l = label -> ());
      match result with Some id -> own (local fr id).value | None -> VUnit)
  | Expr.Record members ->
      sized run e.Expr.ty;
      let v =
        match zero e.Expr.ty with
        | VRecord a -> a
        | _ -> stop "a record of a type that is not a struct"
      in
      List.iter (fun (i, m) -> v.(i) <- expr run fr m) members;
      VRecord v
  | Expr.Member { value; index } -> (
      match (expr run fr value, index) with
      | VRecord a, i when i < Array.length a -> a.(i)
      (* A handle's middle word is its length (emit.ml lays it out as a
         pointer and two counts). *)
      | VList l, 1 -> VInt (Int64.of_int l.count)
      | VText s, 1 -> VInt (Int64.of_int (String.length s))
      | _ -> stop "a member of something that does not have it")
  | Expr.Case { index; payload } -> VCase (index, expr run fr payload)
  | Expr.Payload { value; index } -> read_path (expr run fr value) [ Payload index ]
  | Expr.Offset { base; within; path } -> VPtr (offset (ptr_of (expr run fr base)) within path)
  | Expr.Take { address; layout } -> (
      let p = ptr_of (expr run fr address) in
      match e.Expr.ty with
      | Ty.Void -> VUnit
      | t ->
          sized run t;
          let v = load p in
          store p t (vacate run.prog.layouts layout t v);
          v)
  | Expr.Copy { value; layout } ->
      let v = expr run fr value in
      bytes run (weight v);
      copy run.prog.layouts layout value.Expr.ty v
  | Expr.Box { value; layout } ->
      let v = expr run fr value in
      sized run value.Expr.ty;
      owner (cell ~layout value.Expr.ty v)
  | Expr.Layout l -> VLayout l
  | Expr.Function f -> VFunc f
  | Expr.Global g -> at (global run g)
  | Expr.Escape { value; _ } -> expr run fr value

and stats run fr body = List.iter (stat run fr) body

and stat run fr (s : Stat.t) =
  tick run;
  match s with
  | Stat.Let { id; value } | Stat.Hold { id; value; _ } ->
      let v = expr run fr value in
      sized run value.Expr.ty;
      bind fr id value.Expr.ty v
  | Stat.Scope { body; _ } -> stats run fr body
  | Stat.Assign { value; _ } when value.Expr.ty = Ty.Void -> ignore (expr run fr value)
  | Stat.Assign { place; value } ->
      let v = expr run fr value in
      let c =
        match (Hashtbl.find_opt fr.locals place.Expr.local, place.Expr.deref, place.Expr.path) with
        (* A whole local of the function being folded can be stored into
           whether or not its value is known: the store decides it. *)
        | None, false, [] when Option.is_some fr.outer ->
            let c = cell ~origin:(Outer place.Expr.local) value.Expr.ty VNull in
            Hashtbl.replace fr.locals place.Expr.local c;
            c
        | _ -> local fr place.Expr.local
      in
      let base = if place.Expr.deref then ptr_of c.value else { cell = c; path = []; owned = false } in
      let at = offset base place.Expr.ty place.Expr.path in
      sized run value.Expr.ty;
      store at value.Expr.ty v
  | Stat.Eval e -> ignore (expr run fr e)
  | Stat.Return e -> raise (Returned (expr run fr e))
  | Stat.If { cond; body } -> if bool_of (expr run fr cond) then stats run fr body
  | Stat.Repeat { count; body } ->
      (* The count is read once; a count below one runs the body no times. *)
      let n = int_of (expr run fr count) in
      let i = ref 0L in
      while Int64.compare !i n < 0 do
        tick run;
        stats run fr body;
        i := Int64.succ !i
      done
  | Stat.Switch { value; cases } -> (
      match expr run fr value with
      | VCase (tag, _) -> (
          match List.assoc_opt tag cases with
          | Some body -> stats run fr body
          | None -> stop "a switch with no case for its tag")
      | _ -> stop "a switch on something not a sum")
  | Stat.Leave label -> raise (Left label)
  | Stat.Store { address; value } ->
      let p = ptr_of (expr run fr address) in
      let v = expr run fr value in
      sized run value.Expr.ty;
      store p value.Expr.ty v
  | Stat.Place { address; value; layout } ->
      let p = ptr_of (expr run fr address) in
      let v = expr run fr value in
      sized run value.Expr.ty;
      store p value.Expr.ty v;
      if p.path = [] then p.cell.layout <- Some layout
  | Stat.Overwrite { address; value; layout } ->
      let p = ptr_of (expr run fr address) in
      let v = expr run fr value in
      bytes run (2 * weight v);
      store p value.Expr.ty (overwrite run.prog.layouts layout value.Expr.ty (load p) v)
  | Stat.Reserve { id; ty; _ } ->
      sized run ty;
      bind fr id ty (zero ty)
  | Stat.Spawn { task; thunk; frame; args; dest; _ } ->
      (* Run where it is spawned (O8): its arguments first, in order, then
         the call, whose result is home at once. *)
      let values = List.map (expr run fr) args in
      let held =
        match zero frame with
        | VRecord a ->
            List.iteri (fun i v -> a.(i + 1) <- v) values;
            a
        | _ -> stop "a spawned call's frame that is not a struct"
      in
      let frame_cell = cell frame (VRecord held) in
      bind fr task Ty.Ptr (Value.at frame_cell);
      ignore (call run thunk [ Value.at frame_cell ]);
      Option.iter
        (fun id ->
          let t = match frame with Ty.Struct (r :: _) -> r | _ -> Ty.Void in
          bind fr id t (read_path frame_cell.value [ Member 0 ]))
        dest
  | Stat.Join _ -> ()

(* ---------------------------------------------------------------------- *)
(* Calls and the runtime                                                  *)
(* ---------------------------------------------------------------------- *)

and call run fn args =
  match Hashtbl.find_opt run.prog.funcs fn with
  | None -> stop "a call to a function with no body here"
  | Some f when f.Func.linkage = Linkage.Imported -> stop "a call to a function with no body here"
  | Some f -> (
      if List.length f.Func.params <> List.length args then stop "a call with the wrong arguments";
      (* A call made before with the same arguments gives what it gave then.
         A run that makes a constant changes what a constant's state holds,
         which a call's arguments do not say, so it remembers nothing. *)
      let consts = List.map export args in
      let key =
        if run.making = None && List.for_all Option.is_some consts then
          Some (fn, List.map Option.get consts)
        else None
      in
      match Option.bind key (Key.find_opt run.prog.memo) with
      | Some (result, outputs) ->
          run.outputs <- List.rev_append outputs run.outputs;
          import result
      | None ->
          run.depth <- run.depth + 1;
          if run.depth > max_depth then stop "calls nested too deep";
          let fr = { locals = Hashtbl.create 16; outer = None } in
          List.iter2 (fun (id, ty) v -> bind fr id ty v) f.Func.params args;
          let before = run.outputs in
          let result = try stats run fr f.Func.body; VUnit with Returned v -> v in
          run.depth <- run.depth - 1;
          (match (key, export result) with
          | Some key, Some c ->
              (* What this call output: the newest outputs, back to those
                 there were before it. *)
              let rec since acc l =
                if l == before then acc else match l with x :: r -> since (x :: acc) r | [] -> acc
              in
              Key.replace run.prog.memo key (c, since [] run.outputs)
          | _ -> ());
          result)

and runtime run (fn : Cgt.Runtime.fn) args =
  match (Intrinsics.classify fn, fn, args) with
  | Intrinsics.Input, _, _ -> stop "an input, which only the running program has"
  | _, Cgt.Runtime.Print, [ text ] ->
      run.outputs <- Print (text_of text) :: run.outputs;
      VUnit
  | _, Cgt.Runtime.Set_threads, [ count ] ->
      let n = int_of count in
      run.outputs <- Set_threads n :: run.outputs;
      VInt (if Int64.compare n 1L < 0 then 0L else 1L)
  | _, Cgt.Runtime.Set_threads_auto, [] ->
      run.outputs <- Set_threads_auto :: run.outputs;
      VUnit
  | _, Cgt.Runtime.Text_join, [ l; r ] ->
      let l = text_of l and r = text_of r in
      bytes run (String.length l + String.length r);
      VText (l ^ r)
  | _, Cgt.Runtime.Text_equal, [ l; r ] ->
      let l = text_of l and r = text_of r in
      bytes run (min (String.length l) (String.length r));
      VInt (if String.equal l r then 1L else 0L)
  | _, Cgt.Runtime.List_new, [] -> empty ()
  | _, Cgt.Runtime.List_push, [ list; stride ] -> (
      match load (ptr_of list) with
      | VList l ->
          l.stride <- Int64.to_int (int_of stride);
          if l.count = Array.length l.items then begin
            bytes run (8 * l.count);
            l.items <-
              Array.init (max 4 (2 * l.count)) (fun i -> if i < l.count then l.items.(i) else cell Ty.Void VNull)
          end;
          let c = cell Ty.Void VNull in
          l.items.(l.count) <- c;
          l.count <- l.count + 1;
          at c
      | _ -> stop "a push onto something not a list")
  | _, Cgt.Runtime.List_at, [ list; index; _stride ] -> (
      let i = int_of index in
      match load (ptr_of list) with
      | VList l when Int64.compare i 1L >= 0 && Int64.compare i (Int64.of_int l.count) <= 0 ->
          at l.items.(Int64.to_int i - 1)
      | VList _ -> stop "an index out of range"
      | _ -> stop "an element of something not a list")
  | _, Cgt.Runtime.Array_at, [ array; index; count; _stride ] ->
      let i = int_of index in
      if Int64.compare i 1L < 0 || Int64.compare i (int_of count) > 0 then stop "an index out of range";
      let p = ptr_of array in
      VPtr { p with path = p.path @ [ Member (Int64.to_int i - 1) ] }
  (* Where a constant is made, whether this is the first read is a fact of
     the running program, not of the code: the read stays. A read inside a
     call is the whole call, which folds when the constant does. *)
  | _, (Cgt.Runtime.Constant_begin | Cgt.Runtime.Constant_end), _
    when run.depth = 0 && run.making = None ->
      stop "where a package constant is made"
  | _, Cgt.Runtime.Constant_begin, [ state ] -> (
      let p = ptr_of state in
      match load p with
      | VInt -1L -> VInt 0L
      | VInt 0L ->
          store p Ty.I64 (VInt 1L);
          VInt 1L
      | VInt _ -> stop "a package constant read while it is made"
      | _ -> stop "a package constant that does not fold")
  | _, Cgt.Runtime.Constant_end, [ state; _value; _layout ] ->
      store (ptr_of state) Ty.I64 (VInt (-1L));
      VUnit
  | _, Cgt.Runtime.Writeback, [ target; copy; _size; _layout ] ->
      let from = ptr_of copy in
      store (ptr_of target) from.cell.ty (load from);
      VUnit
  | _ -> stop "a runtime call the tree does not make"
