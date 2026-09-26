(* Lowering: the TST to the CGT (docs/lowering.md).

   What is lowered is what `main` reaches. A verb is lowered once, the first
   time a call reaches it, so a program pays only for the verbs it uses and a
   package's other declarations need not lower yet. Anything lowering cannot
   handle yet is refused with a diagnostic at the node, rather than lowered
   wrongly. *)

module T = Tst.Nodes
module S = Tst.Signature
module Tty = Tst.Ty
open Nodes

type problem = Diagnostic of Diagnostic.t | Message of string

exception Refused of problem

let refuse span message = raise (Refused (Diagnostic (Diagnostic.error span message)))

(* ---------------------------------------------------------------------- *)
(* State                                                                  *)
(* ---------------------------------------------------------------------- *)

type verb = { decl : int; signature : S.t; params : T.Local.t list; body : T.Block.t }

(* What a TST local stands for where lowering reads it. A verb that is
   expanded (L11) binds its parameters to these: a slot of the function it is
   expanded into, a literal its concept parameter was given, or the code of a
   block argument. A `mut` subject is a [Pointer]: a slot holding the address
   of the caller's place (L6). *)
type binding = Slot of int | Pointer of int | Literal of T.Expr.t | Code of closure

(* A block argument keeps the context it was written in, so its locals and
   its `return` mean what they meant there. *)
and closure = { block : T.Block.t; ctx : ctx }

and ctx = {
  env : (int, binding) Hashtbl.t;
  (* Where a `return` goes: out of the function, or out of the expansion
     that is being lowered, storing its result. *)
  exit : exit;
  (* The verbs being expanded around this point, so one that would expand
     into itself is refused rather than expanded forever. *)
  expanding : int list;
  (* Where an `abort` goes (L12): out of the function by its aborted
     outcome, or into the handler of the call or `match` it belongs to. *)
  abort : Source.Span.t -> Expr.t -> Stat.t list;
  (* Where a `resolve` goes: past the operation its handler handles. *)
  resolve : (Expr.t -> Stat.t list) option;
  (* What ends this invocation with `Unit`: a return from the function, or
     leaving the expansion (control-flow.md §4.2). *)
  finish : Source.Span.t -> Stat.t list;
  (* What `@controlflow$exitFromCall` does here: end the invocation that
     called the verb whose body it is in. *)
  exit_call : Source.Span.t -> Stat.t list;
}

and exit = Function | Leave of { label : int; result : int option }

type state = {
  verbs : (int, verb) Hashtbl.t;
  (* Each declared type's definition and whether it is a reference type. *)
  types : (string * string, T.Decl.definition * bool) Hashtbl.t;
  (* Each enum map: the enum it ranges over, and its entries. *)
  maps : (int, Tty.t * (string * T.Expr.t) list) Hashtbl.t;
  (* Symbols already lowered or on their way, and the verbs still to lower. *)
  symbols : (int, string) Hashtbl.t;
  pending : verb Queue.t;
  (* The next local or label of the function being lowered. *)
  mutable next : int;
  (* What a `return` from the function being lowered returns its value as:
     itself, or the done case of its outcome (L12). *)
  mutable returns : Expr.t -> Expr.t;
}

let fresh st =
  st.next <- st.next + 1;
  st.next

(* ---------------------------------------------------------------------- *)
(* Types                                                                  *)
(* ---------------------------------------------------------------------- *)

let unhandled span t =
  refuse span (Printf.sprintf "lowering does not handle `%s` yet" (Tty.to_string t))

let definition st (t : Tty.t) =
  match t with
  | Tty.Named ({ package; name }, []) -> Hashtbl.find_opt st.types (package, name)
  | _ -> None

(* A value struct of one member is that member (L5), so reading or storing
   the member is reading or storing the struct. *)
let collapsed st t =
  match definition st t with Some (T.Decl.Struct [ _ ], false) -> true | _ -> false

(* L5: a storage primitive has a machine layout. A value struct has its
   members' in declaration order, except that one of a single member has that
   member's (concepts-vs-primitives.md) and an empty one, like `core`'s
   `Unit`, has none. A value variant is a sum of its payloads, and an enum a
   sum of cases with none. *)
let rec ty ?(seen = []) st span (t : Tty.t) : Nodes.Ty.t =
  match t with
  | Tty.Intrinsic { namespace = "primitives"; name; args = [] } -> (
      match name with
      | "Unit" -> Nodes.Ty.Void
      | "Bool" -> Nodes.Ty.I1
      | "Int" | "I64" -> Nodes.Ty.I64
      | "Float" -> Nodes.Ty.F64
      | "String" -> Nodes.Ty.View
      | _ -> unhandled span t)
  | Tty.Named (id, []) -> (
      (* A value type that contains itself has a boxed member (adt.md §4),
         which lives in the dynamic region (step 7). *)
      if List.mem id seen then unhandled span t;
      let member = ty ~seen:(id :: seen) st span in
      match definition st t with
      | Some (T.Decl.Struct [], false) -> Nodes.Ty.Void
      | Some (T.Decl.Struct [ (_, m) ], false) -> member m
      | Some (T.Decl.Struct ms, false) -> Nodes.Ty.Struct (List.map (fun (_, m) -> member m) ms)
      | Some (T.Decl.Variant cs, false) -> Nodes.Ty.Sum (List.map (fun (_, c) -> member c) cs)
      | Some (T.Decl.Enum cs, _) -> Nodes.Ty.Sum (List.map (fun _ -> Nodes.Ty.Void) cs)
      | Some (T.Decl.Distinct u, false) -> member u
      | _ -> unhandled span t)
  | _ -> unhandled span t

(* The cases of a variant or enum, in declaration order. *)
let cases st span t =
  match definition st t with
  | Some (T.Decl.Variant cs, _) -> List.map fst cs
  | Some (T.Decl.Enum cs, _) -> cs
  | _ -> unhandled span t

let case_index st span t case =
  let rec find i = function
    | [] -> refuse span (Printf.sprintf "`%s` has no case `%s`" (Tty.to_string t) case)
    | c :: _ when c = case -> i
    | _ :: rest -> find (i + 1) rest
  in
  find 0 (cases st span t)

(* ---------------------------------------------------------------------- *)
(* Literals                                                               *)
(* ---------------------------------------------------------------------- *)

(* The spec names no escapes (lexical.md); the lexer keeps a backslash and the
   character after it together, and these are the ones lowering decodes
   (docs/lowering.md §9). Any other pair stands for itself. *)
let unescape s =
  let b = Buffer.create (String.length s) in
  let n = String.length s in
  let rec go i =
    if i < n then
      if s.[i] = '\\' && i + 1 < n then begin
        (match s.[i + 1] with
        | 'n' -> Buffer.add_char b '\n'
        | 't' -> Buffer.add_char b '\t'
        | 'r' -> Buffer.add_char b '\r'
        | '0' -> Buffer.add_char b '\000'
        | c -> Buffer.add_char b c);
        go (i + 2)
      end
      else begin
        Buffer.add_char b s.[i];
        go (i + 1)
      end
  in
  go 0;
  Buffer.contents b

let lookup ctx span (l : T.Local.t) =
  match Hashtbl.find_opt ctx.env l.T.Local.id with
  | Some b -> b
  | None -> refuse span (Printf.sprintf "lowering found no slot for `%s`" l.T.Local.name)

(* A literal, read through the concept parameters it was passed on by. *)
let rec literal_of ctx (e : T.Expr.t) =
  match e.T.Expr.node with
  | T.Expr.Var (T.Name_ref.Local l) -> (
      match lookup ctx e.T.Expr.span l with
      | Literal lit -> literal_of ctx lit
      | _ -> e)
  | _ -> e

(* A storage primitive's constructor embeds its literal (types.md §2.7). *)
let literal ctx span name (arg : T.Expr.t) : Expr.t =
  match (name, (literal_of ctx arg).T.Expr.node) with
  | "Int", T.Expr.Integer_lit s | "I64", T.Expr.Integer_lit s -> (
      match Int64.of_string_opt s with
      | Some i -> { Expr.node = Expr.Int i; ty = Nodes.Ty.I64 }
      | None -> refuse span (Printf.sprintf "`%s` is out of range for `@primitives$Int`" s))
  | "Float", T.Expr.Decimal_lit s ->
      { Expr.node = Expr.Float (float_of_string s); ty = Nodes.Ty.F64 }
  | "String", T.Expr.Text_lit s -> { Expr.node = Expr.Text (unescape s); ty = Nodes.Ty.View }
  | _ -> refuse span (Printf.sprintf "lowering does not handle this `@primitives$%s` yet" name)

(* ---------------------------------------------------------------------- *)
(* Verbs                                                                  *)
(* ---------------------------------------------------------------------- *)

(* An operator's symbol spells its token as a word, and an intrinsic type's
   loses its `@`. *)
let sanitize name =
  match name with
  | "+" -> "plus"
  | "*" -> "times"
  | "/" -> "over"
  | "==" -> "equals"
  | "<" -> "less"
  | "~" -> "flip"
  | "[]" -> "index"
  | _ ->
      String.concat ""
        (List.map
           (fun c ->
             match c with
             | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> String.make 1 c
             | '@' -> ""
             | _ -> "_")
           (List.init (String.length name) (String.get name)))

(* A verb's symbol names its declaration, so two overloads never share one. *)
let symbol st (v : verb) =
  match Hashtbl.find_opt st.symbols v.decl with
  | Some s -> s
  | None ->
      let s = Printf.sprintf "zane_%s_%d" (sanitize v.signature.S.name) v.decl in
      Hashtbl.replace st.symbols v.decl s;
      Queue.add v st.pending;
      s

(* L11: a verb with a concept parameter -- a block, or a literal it embeds --
   has no function. Each call to it is replaced by its body. *)
let expands (v : verb) =
  List.exists
    (fun (p : T.Local.t) -> match p.T.Local.ty with Tty.Concept _ -> true | _ -> false)
    v.params

(* How a verb's call can end (L12): its primary result, and the abort value
   when it declares an abort type, and an exit when it has one. *)
type outcome = { ok : Nodes.Ty.t; aborts : Nodes.Ty.t option; exit_ : bool }

let outcome st span (v : verb) =
  {
    ok = ty st span v.signature.S.ret;
    aborts = Option.map (ty st span) v.signature.S.abort;
    exit_ = Tst.Exits.block v.body;
  }

(* A function that can end more than one way returns a sum of the three:
   done with its result, aborted with its abort value, or exited
   (docs/lowering.md §9). One that can only finish returns its result. *)
let plain o = o.aborts = None && not o.exit_

let returned o =
  if plain o then o.ok
  else Nodes.Ty.Sum [ o.ok; Option.value o.aborts ~default:Nodes.Ty.Void; Nodes.Ty.Void ]

let done_ = 0
let aborted = 1
let exited = 2

let outcome_case o index (payload : Expr.t) =
  { Expr.node = Expr.Case { index; payload }; ty = returned o }

let unit_ = { Expr.node = Expr.Unit; ty = Nodes.Ty.Void }

(* A `mut` method's subject, which is passed by address (L6). *)
let is_subject (v : verb) (p : T.Local.t) = v.signature.S.is_mut && p.T.Local.name = "this"

let deref id t = { Expr.node = Expr.Deref { Expr.node = Expr.Local id; ty = Nodes.Ty.Ptr }; ty = t }

let binop : Sst.Nodes.Operator.node -> Expr.binop = function
  | Add -> Expr.Add
  | Mul -> Expr.Mul
  | Div -> Expr.Div
  | Eq -> Expr.Eq
  | Less -> Expr.Less

(* A storage primitive's constructor: `Unit` has no storage, and the others
   embed their literal. *)
let primitive ctx span spelling args : Expr.t =
  let prefix = "@primitives$" in
  let n = String.length prefix in
  let name =
    if String.length spelling > n && String.sub spelling 0 n = prefix then
      String.sub spelling n (String.length spelling - n)
    else spelling
  in
  match (name, args) with
  | "Unit", [] -> { Expr.node = Expr.Unit; ty = Nodes.Ty.Void }
  | _, [ T.Arg.Value v ] -> literal ctx span name v
  | _ -> refuse span (Printf.sprintf "lowering does not handle `%s` yet" spelling)

(* An exit ends the run of a block (docs/spec-divergences.md §11). Semantics
   rejects one anywhere else, so this is not reached. *)
let no_block span = refuse span "an exit ends the block its call is written in, and this is in none"

(* Where nothing leaves: an enum map's entry, which is a constant. *)
let constant_ctx () =
  let nowhere span = refuse span "lowering expected nothing here to leave" in
  {
    env = Hashtbl.create 1;
    exit = Function;
    expanding = [];
    abort = (fun span _ -> nowhere span);
    resolve = None;
    finish = nowhere;
    exit_call = nowhere;
  }

let rec expr st ctx (e : T.Expr.t) : Expr.t =
  let span = e.T.Expr.span in
  match e.T.Expr.node with
  | T.Expr.Var (T.Name_ref.Local l) -> (
      match lookup ctx span l with
      | Slot id -> { Expr.node = Expr.Local id; ty = ty st span l.T.Local.ty }
      | Pointer id -> deref id (ty st span l.T.Local.ty)
      | Literal _ | Code _ -> refuse span "lowering does not read this parameter as a value")
  | T.Expr.Bool_lit b -> { Expr.node = Expr.Bool b; ty = Nodes.Ty.I1 }
  | T.Expr.Construct { ctor = { owner = S.Intrinsic spelling; _ }; args; handler = None } ->
      primitive ctx span spelling args
  | T.Expr.Coerce { ctor = { owner = S.Intrinsic spelling; _ }; value } ->
      primitive ctx span spelling [ T.Arg.Value value ]
  | T.Expr.Construct { ctor = { owner = S.Declared id; instance = []; _ }; args; handler }
  | T.Expr.Call { callee = { owner = S.Declared id; instance = []; _ }; args; handler } ->
      call st ctx span id args handler e.T.Expr.ty
  | T.Expr.Coerce { ctor = { owner = S.Declared id; instance = []; _ }; value } ->
      call st ctx span id [ T.Arg.Value value ] None e.T.Expr.ty
  | T.Expr.Call { callee = { owner = S.Intrinsic "@runtime$print"; _ }; args; handler = None }
    -> (
      (* The program has one console (effects.md §6.6), so the subject names
         nothing the runtime needs. The text is a guest to a place in this
         frame, and the runtime reads the view stored there (L10). *)
      match args with
      | [ T.Arg.Value _console; T.Arg.Value text ] ->
          {
            Expr.node = Expr.Runtime { fn = "zane_print"; args = [ expr st ctx text ] };
            ty = Nodes.Ty.Void;
          }
      | _ -> refuse span "lowering does not handle this call to `print`")
  | T.Expr.Op { op; impl = { owner; instance = []; _ }; left; right; swapped; handler } ->
      let t = ty st span e.T.Expr.ty in
      let apply l r =
        match owner with
        | S.Intrinsic _ ->
            { Expr.node = Expr.Binary { op = binop op; left = l; right = r }; ty = t }
        | S.Declared id -> (
            match Hashtbl.find_opt st.verbs id with
            | Some v when not (expands v) -> invoke st ctx span v [ l; r ] handler
            | _ -> refuse span "lowering does not handle this operator yet")
      in
      (* Operands run in the order they were written, which is the other way
         round when the desugaring swapped them (operators.md §2.3). *)
      if swapped then in_order st ctx t right left (fun r l -> apply l r)
      else
        let l = expr st ctx left in
        apply l (expr st ctx right)
  | T.Expr.Flip { impl = { owner = S.Intrinsic _; _ }; value; handler = None } ->
      { Expr.node = Expr.Flip (expr st ctx value); ty = ty st span e.T.Expr.ty }
  | T.Expr.Flip { impl = { owner = S.Declared id; instance = []; _ }; value; handler } ->
      call st ctx span id [ T.Arg.Value value ] handler e.T.Expr.ty
  | T.Expr.Field { target; slot; _ } ->
      let t = ty st span e.T.Expr.ty in
      if collapsed st target.T.Expr.ty then { (expr st ctx target) with ty = t }
      else { Expr.node = Expr.Member { value = expr st ctx target; index = slot }; ty = t }
  | T.Expr.Init fields | T.Expr.Construct_fields { fields; handler = None; _ } ->
      record st ctx span e.T.Expr.ty fields
  | T.Expr.Case { case; payload } ->
      let index = case_index st span e.T.Expr.ty case in
      let payload = expr st ctx payload in
      { Expr.node = Expr.Case { index; payload }; ty = ty st span e.T.Expr.ty }
  | T.Expr.Enum_member case ->
      let index = case_index st span e.T.Expr.ty case in
      let payload = { Expr.node = Expr.Unit; ty = Nodes.Ty.Void } in
      { Expr.node = Expr.Case { index; payload }; ty = ty st span e.T.Expr.ty }
  | T.Expr.Match { scrutinees; arms; handler } ->
      match_ st ctx span scrutinees arms handler e.T.Expr.ty
  | T.Expr.Case_read { target; case; handler } ->
      case_read st ctx span target case handler e.T.Expr.ty
  | T.Expr.Map_read { target; map; _ } -> map_read st ctx span target map e.T.Expr.ty
  | _ -> refuse span "lowering does not handle this expression yet"

(* A struct built member by member, in the order they were written. One of a
   single member is that member, and an empty one is nothing (L5). *)
and record st ctx span t (fields : T.Field_value.t list) =
  let lowered = ty st span t in
  match (lowered, fields) with
  | Nodes.Ty.Void, [] -> { Expr.node = Expr.Unit; ty = Nodes.Ty.Void }
  | Nodes.Ty.Struct members, _ when List.length members = List.length fields ->
      let fields =
        List.map (fun (f : T.Field_value.t) -> (f.T.Field_value.slot, expr st ctx f.value)) fields
      in
      { Expr.node = Expr.Record fields; ty = lowered }
  | _, [ f ] when collapsed st t -> { (expr st ctx f.T.Field_value.value) with ty = lowered }
  | _ -> refuse span "lowering does not fill a member's default yet"

(* L13. The scrutinees are stored once, in order, and a switch on each one's
   tag nests inside the last; the semantic pass wrote one arm per
   combination of cases, so each arm is lowered once, where its combination
   is reached. A `return` in an arm is the `match`'s value. *)
and match_ st ctx span scrutinees (arms : T.Arm.t list) handler ret =
  let t = ty st span ret in
  let label = fresh st in
  let result = if t = Nodes.Ty.Void then None else Some (fresh st) in
  let stored =
    List.map
      (fun (e : T.Expr.t) ->
        let value = expr st ctx e in
        let id = fresh st in
        (id, value.Expr.ty, e.T.Expr.ty, Stat.Let { id; value }))
      scrutinees
  in
  (* An arm's abort is the `match`'s (error-handling.md §3.5). *)
  let abort = match handler with Some h -> handle st ctx h label result | None -> ctx.abort in
  let inner = { ctx with exit = Leave { label; result }; abort } in
  let selects chosen (a : T.Arm.t) =
    List.map (fun (p : T.Pattern.t) -> p.T.Pattern.case) a.patterns = chosen
  in
  let arm chosen =
    match List.find_opt (selects chosen) arms with
    | None -> refuse span "lowering found no arm for a combination of cases"
    | Some a ->
        let binds =
          List.concat
            (List.map2
               (fun (p : T.Pattern.t) (id, sty, tsty, _) ->
                 match p.T.Pattern.binder with
                 | None -> []
                 | Some l ->
                     let index = case_index st span tsty p.case in
                     let payload = ty st span l.T.Local.ty in
                     let source = { Expr.node = Expr.Local id; ty = sty } in
                     let value =
                       { Expr.node = Expr.Payload { value = source; index }; ty = payload }
                     in
                     let bound = fresh st in
                     Hashtbl.replace ctx.env l.T.Local.id (Slot bound);
                     [ Stat.Let { id = bound; value } ])
               a.patterns stored)
        in
        binds @ block st inner a.body
  in
  let rec dispatch chosen = function
    | [] -> arm (List.rev chosen)
    | (id, sty, tsty, _) :: rest ->
        let cases =
          List.mapi (fun i c -> (i, dispatch (c :: chosen) rest)) (cases st span tsty)
        in
        [ Stat.Switch { value = { Expr.node = Expr.Local id; ty = sty }; cases } ]
  in
  let lets = List.map (fun (_, _, _, l) -> l) stored in
  { Expr.node = Expr.Expand { label; body = lets @ dispatch [] stored; result }; ty = t }

(* An enum map read is a switch on the member, each case giving its entry. *)
and map_read st ctx span target map ret =
  match Hashtbl.find_opt st.maps map with
  | None -> refuse span "lowering found no enum map here"
  | Some (enum, entries) ->
      let t = ty st span ret in
      let label = fresh st in
      let result = if t = Nodes.Ty.Void then None else Some (fresh st) in
      let value = expr st ctx target in
      let id = fresh st in
      let entry_ctx = { (constant_ctx ()) with expanding = ctx.expanding } in
      let cases =
        List.mapi
          (fun i member ->
            match List.assoc_opt member entries with
            | Some e -> (i, leave label result (expr st entry_ctx e))
            | None -> refuse span (Printf.sprintf "the enum map has no entry for `%s`" member))
          (cases st span enum)
      in
      {
        Expr.node =
          Expr.Expand
            {
              label;
              body =
                [
                  Stat.Let { id; value };
                  Stat.Switch { value = { Expr.node = Expr.Local id; ty = value.Expr.ty }; cases };
                ];
              result;
            };
        ty = t;
      }

(* A handler, run where its operation aborted: its binder holds the abort
   value, and a `resolve` gives the operation its value and goes past it. *)
and handle st ctx (h : T.Handler.t) label result _span (value : Expr.t) =
  let bind =
    match h.T.Handler.binder with
    | Some l ->
        let id = fresh st in
        Hashtbl.replace ctx.env l.T.Local.id (Slot id);
        [ Stat.Let { id; value } ]
    | None -> [ Stat.Eval value ]
  in
  bind @ block st { ctx with resolve = Some (leave label result) } h.T.Handler.body

(* A case read is its payload when the case is live, and runs its handler
   when another is (adt.md §5.2). The other cases fall through to it. *)
and case_read st ctx span (target : T.Expr.t) case handler ret =
  let t = ty st span ret in
  let label = fresh st in
  let result = if t = Nodes.Ty.Void then None else Some (fresh st) in
  let value = expr st ctx target in
  let id = fresh st in
  let live = case_index st span target.T.Expr.ty case in
  let source = { Expr.node = Expr.Local id; ty = value.Expr.ty } in
  let cases =
    List.mapi
      (fun i _ ->
        if i = live then
          (i, leave label result { Expr.node = Expr.Payload { value = source; index = i }; ty = t })
        else (i, []))
      (cases st span target.T.Expr.ty)
  in
  let otherwise = handle st ctx handler label result span unit_ in
  let body = [ Stat.Let { id; value }; Stat.Switch { value = source; cases } ] @ otherwise in
  { Expr.node = Expr.Expand { label; body; result }; ty = t }

(* What a `return` to an expansion does: store the result, and leave. *)
and leave label result value =
  match result with
  | Some id -> [ Stat.assign id value; Stat.Leave label ]
  | None -> [ Stat.Eval value; Stat.Leave label ]

(* Two operands stored in the order they are given, then combined. *)
and in_order st ctx t first second combine =
  let store (e : T.Expr.t) =
    let v = expr st ctx e in
    let id = fresh st in
    ({ Expr.node = Expr.Local id; ty = v.Expr.ty }, Stat.Let { id; value = v })
  in
  let a, let_a = store first in
  let b, let_b = store second in
  let label = fresh st in
  let result = fresh st in
  {
    Expr.node =
      Expr.Expand
        {
          label;
          body = [ let_a; let_b; Stat.assign result (combine a b) ];
          result = Some result;
        };
    ty = t;
  }

and call st ctx span id args handler ret : Expr.t =
  match Hashtbl.find_opt st.verbs id with
  | None -> refuse span "lowering does not handle a call to this verb yet"
  | Some v when expands v -> expand st ctx span v args handler ret
  | Some v ->
      let args =
        List.map2
          (fun (p : T.Local.t) arg ->
            match arg with
            | T.Arg.Value a when is_subject v p -> address st ctx span a
            | T.Arg.Value a -> expr st ctx a
            | T.Arg.Block _ -> refuse span "lowering does not expand block arguments here")
          v.params args
      in
      invoke st ctx span v args handler

(* L12. A call that can end more than one way is switched on how it ended:
   done gives its result, aborted runs its handler, or the abort of the
   `match` it flows out of, and an exit ends this invocation too. *)
and invoke st ctx span v args handler =
  let o = outcome st span v in
  let value = { Expr.node = Expr.Call { fn = symbol st v; args }; ty = returned o } in
  if plain o then value
  else
    let label = fresh st in
    let result = if o.ok = Nodes.Ty.Void then None else Some (fresh st) in
    let id = fresh st in
    let source = { Expr.node = Expr.Local id; ty = value.Expr.ty } in
    let payload index t = { Expr.node = Expr.Payload { value = source; index }; ty = t } in
    let on_abort =
      match handler with Some h -> handle st ctx h label result | None -> ctx.abort
    in
    let finished =
      if o.ok = Nodes.Ty.Void then [ (done_, [ Stat.Leave label ]) ]
      else [ (done_, leave label result (payload done_ o.ok)) ]
    in
    let failed =
      match o.aborts with Some a -> [ (aborted, on_abort span (payload aborted a)) ] | None -> []
    in
    let left = if o.exit_ then [ (exited, ctx.finish span) ] else [] in
    let cases = finished @ failed @ left in
    let body = [ Stat.Let { id; value }; Stat.Switch { value = source; cases } ] in
    { Expr.node = Expr.Expand { label; body; result }; ty = o.ok }

(* L11. A parameter is bound to what it stands for in the body: a block
   argument to its code, a literal to itself, the subject to the caller's
   place, and any other argument to a new slot holding its value (L6). *)
(* L6: a `mut` subject is passed as the address of the caller's place. *)
and address st ctx span (a : T.Expr.t) =
  let ptr node = { Expr.node; ty = Nodes.Ty.Ptr } in
  match a.T.Expr.node with
  | T.Expr.Var (T.Name_ref.Local l) -> (
      match lookup ctx span l with
      | Slot id -> ptr (Expr.Address id)
      | Pointer id -> ptr (Expr.Local id)
      | _ -> refuse span "lowering expected a place here")
  | _ -> refuse span "lowering does not pass a `mut` subject other than a local yet"

and expand st ctx span v args handler ret =
  if List.mem v.decl ctx.expanding then
    refuse span (Printf.sprintf "`%s` expands into itself" v.signature.S.name);
  if List.length args <> List.length v.params then
    refuse span "lowering does not fill a default argument yet";
  let env = Hashtbl.create 8 in
  let bind (p : T.Local.t) b = Hashtbl.replace env p.T.Local.id b in
  let binds =
    List.concat
      (List.map2
         (fun (p : T.Local.t) arg ->
           match (arg, p.T.Local.ty) with
           | T.Arg.Block block, _ ->
               bind p (Code { block; ctx });
               []
           | T.Arg.Value a, Tty.Concept Tty.Block -> (
               match a.T.Expr.node with
               | T.Expr.Var (T.Name_ref.Local l) -> (
                   match lookup ctx span l with
                   | Code c ->
                       bind p (Code c);
                       []
                   | _ -> refuse span "lowering expected a block here")
               | _ -> refuse span "lowering expected a block here")
           | T.Arg.Value a, Tty.Concept _ ->
               bind p (Literal (literal_of ctx a));
               []
           | T.Arg.Value { T.Expr.node = T.Expr.Var (T.Name_ref.Local l); _ }, _
             when p.T.Local.name = "this" -> (
               match lookup ctx span l with
               | (Slot _ | Pointer _) as b ->
                   bind p b;
                   []
               | _ -> refuse span "lowering expected a place here")
           (* A `mut` method writes its subject, so a copy would lose the
              write. *)
           | T.Arg.Value _, _ when p.T.Local.name = "this" && v.signature.S.is_mut ->
               refuse span "lowering does not pass a `mut` subject other than a local yet"
           | T.Arg.Value a, _ ->
               let value = expr st ctx a in
               let id = fresh st in
               bind p (Slot id);
               [ Stat.Let { id; value } ])
         v.params args)
  in
  let t = ty st span ret in
  let label = fresh st in
  let result = if t = Nodes.Ty.Void then None else Some (fresh st) in
  (* An exit in the body ends the invocation the call was written in, and
     one that body calls ends the expansion (control-flow.md §4.2). *)
  let inner =
    {
      env;
      exit = Leave { label; result };
      expanding = v.decl :: ctx.expanding;
      abort = (match handler with Some h -> handle st ctx h label result | None -> ctx.abort);
      resolve = None;
      finish = no_block;
      exit_call = ctx.finish;
    }
  in
  match binds @ block st inner v.body with
  (* A body that only returns a value is that value. *)
  | [ Stat.Assign { place = { local; path = []; deref = false; _ }; value }; Stat.Leave l ]
    when Some local = result && l = label ->
      value
  | [ Stat.Eval value; Stat.Leave l ] when result = None && l = label -> value
  | body -> { Expr.node = Expr.Expand { label; body; result }; ty = t }

and block st ctx (b : T.Block.t) = List.concat_map (stat st ctx) b.T.Block.stats

(* A block argument's code, where it was written. An exit ends this run of
   it (docs/spec-divergences.md §11). *)
and code st ctx span (arg : T.Arg.t) =
  let run ctx b =
    let label = fresh st in
    let left = ref false in
    let finish _ =
      left := true;
      [ Stat.Leave label ]
    in
    let body = block st { ctx with finish } b in
    if !left then
      [ Stat.Eval { Expr.node = Expr.Expand { label; body; result = None }; ty = Nodes.Ty.Void } ]
    else body
  in
  match arg with
  | T.Arg.Block b -> run ctx b
  | T.Arg.Value { T.Expr.node = T.Expr.Var (T.Name_ref.Local l); _ } -> (
      match lookup ctx span l with
      | Code c -> run c.ctx c.block
      | _ -> refuse span "lowering expected a block here")
  | T.Arg.Value _ -> refuse span "lowering expected a block here"

and stat st ctx (s : T.Stat.t) : Stat.t list =
  let span = s.T.Stat.span in
  match s.T.Stat.node with
  | T.Stat.Let { local; value } ->
      let value = expr st ctx value in
      let id = fresh st in
      Hashtbl.replace ctx.env local.T.Local.id (Slot id);
      [ Stat.Let { id; value } ]
  | T.Stat.Assign { target; value } ->
      let place = place st ctx span target in
      [ Stat.Assign { place; value = expr st ctx value } ]
  | T.Stat.Expr
      {
        T.Expr.node =
          T.Expr.Call { callee = { owner = S.Intrinsic spelling; _ }; args; handler = None };
        _;
      }
    when String.length spelling > 13 && String.sub spelling 0 13 = "@controlflow$" -> (
      match (spelling, args) with
      | "@controlflow$branch", [ T.Arg.Value cond; body ] ->
          let cond = expr st ctx cond in
          [ Stat.If { cond; body = code st ctx span body } ]
      | "@controlflow$repeat", [ T.Arg.Value count; body ] ->
          let count = expr st ctx count in
          [ Stat.Repeat { count; body = code st ctx span body } ]
      | "@controlflow$exitFromCall", [] -> ctx.exit_call span
      | _ -> refuse span (Printf.sprintf "lowering does not handle `%s` yet" spelling))
  | T.Stat.Expr e -> [ Stat.Eval (expr st ctx e) ]
  | T.Stat.Return e -> (
      let value = expr st ctx e in
      match ctx.exit with
      | Function -> [ Stat.Return (st.returns value) ]
      | Leave { label; result } -> leave label result value)
  | T.Stat.Abort e -> ctx.abort span (expr st ctx e)
  | T.Stat.Resolve e -> (
      match ctx.resolve with
      | Some resolve -> resolve (expr st ctx e)
      | None -> refuse span "lowering does not handle a block that yields a value yet")
  | _ -> refuse span "lowering does not handle this statement yet"

(* Where an assignment stores: a local, or the place a `mut` subject points
   at, and the members below it. A struct of one member adds no step. *)
and place st ctx span (target : T.Expr.t) : Expr.place =
  match target.T.Expr.node with
  | T.Expr.Var (T.Name_ref.Local l) -> (
      let t = ty st span l.T.Local.ty in
      match lookup ctx span l with
      | Slot local -> { local; deref = false; ty = t; path = [] }
      | Pointer local -> { local; deref = true; ty = t; path = [] }
      | _ -> refuse span "lowering expected a place here")
  | T.Expr.Field { target = inner; slot; _ } ->
      let p = place st ctx span inner in
      if collapsed st inner.T.Expr.ty then p else { p with path = p.path @ [ slot ] }
  | _ -> refuse span "lowering does not store into this place yet"

let func st (v : verb) : Func.t =
  let span = v.body.T.Block.span in
  st.next <- 0;
  let env = Hashtbl.create 16 in
  let params =
    List.map
      (fun (p : T.Local.t) ->
        let id = fresh st in
        if is_subject v p then begin
          Hashtbl.replace env p.T.Local.id (Pointer id);
          (id, Nodes.Ty.Ptr)
        end
        else begin
          Hashtbl.replace env p.T.Local.id (Slot id);
          (id, ty st p.T.Local.span p.T.Local.ty)
        end)
      v.params
  in
  let o = outcome st span v in
  st.returns <- (if plain o then Fun.id else outcome_case o done_);
  let ctx =
    {
      env;
      exit = Function;
      expanding = [];
      abort = (fun _ value -> [ Stat.Return (outcome_case o aborted value) ]);
      resolve = None;
      finish = no_block;
      exit_call = (fun _ -> [ Stat.Return (outcome_case o exited unit_) ]);
    }
  in
  { Func.symbol = symbol st v; params; ret = returned o; body = block st ctx v.body }

(* ---------------------------------------------------------------------- *)
(* Programs                                                               *)
(* ---------------------------------------------------------------------- *)

let program (p : T.Program.t) =
  let st =
    {
      verbs = Hashtbl.create 64;
      types = Hashtbl.create 64;
      maps = Hashtbl.create 16;
      symbols = Hashtbl.create 64;
      pending = Queue.create ();
      next = 0;
      returns = Fun.id;
    }
  in
  List.iter
    (fun (pkg : T.Package.t) ->
      List.iter
        (fun (d : T.Decl.t) ->
          match d.T.Decl.node with
          | T.Decl.Type { name; params = []; reference; definition } ->
              Hashtbl.replace st.types (pkg.T.Package.name, name) (definition, reference)
          | T.Decl.Enum_map { enum; entries; _ } ->
              Hashtbl.replace st.maps d.T.Decl.id (enum, entries)
          | T.Decl.Verb { signature; body = T.Decl.Checked { params; body } } ->
              Hashtbl.replace st.verbs d.T.Decl.id
                { decl = d.T.Decl.id; signature; params; body }
          | _ -> ())
        pkg.T.Package.decls)
    p.T.Program.packages;
  try
    (* The root package is the first (docs/semantics.md §2), and its `main`
       is where the program starts (packages.md §6.2). *)
    let root =
      match p.T.Program.packages with
      | r :: _ -> r
      | [] -> raise (Refused (Message "no packages"))
    in
    let main =
      List.find_map
        (fun (d : T.Decl.t) ->
          match d.T.Decl.node with
          | T.Decl.Verb { signature; _ } when signature.S.name = "main" ->
              Hashtbl.find_opt st.verbs d.T.Decl.id
          | _ -> None)
        root.T.Package.decls
    in
    match main with
    | None ->
        raise
          (Refused
             (Message
                (Printf.sprintf "the root package `%s` declares no `main` to start from"
                   root.T.Package.name)))
    | Some main ->
        (* The runtime calls `main` and reads no outcome from it. *)
        let span = main.body.T.Block.span in
        if not (plain (outcome st span main)) then
          refuse span "`main` has no caller to abort to or exit";
        let entry = symbol st main in
        (* In the order calls first reach them, `main` first. *)
        let rec drain acc =
          match Queue.take_opt st.pending with
          | None -> List.rev acc
          | Some v -> drain (func st v :: acc)
        in
        Ok { Program.funcs = drain []; entry }
  with Refused problem -> Error problem
