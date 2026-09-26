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
   block argument. *)
type binding = Slot of int | Literal of T.Expr.t | Code of closure

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
}

and exit = Function | Leave of { label : int; result : int option }

type state = {
  verbs : (int, verb) Hashtbl.t;
  (* Each declared type's definition and whether it is a reference type. *)
  types : (string * string, T.Decl.definition * bool) Hashtbl.t;
  (* Symbols already lowered or on their way, and the verbs still to lower. *)
  symbols : (int, string) Hashtbl.t;
  pending : verb Queue.t;
  (* The next local or label of the function being lowered. *)
  mutable next : int;
}

let fresh st =
  st.next <- st.next + 1;
  st.next

(* ---------------------------------------------------------------------- *)
(* Types                                                                  *)
(* ---------------------------------------------------------------------- *)

let unhandled span t =
  refuse span (Printf.sprintf "lowering does not handle `%s` yet" (Tty.to_string t))

(* L5: a storage primitive has a machine layout, and a value struct around
   one member has that member's (concepts-vs-primitives.md). An empty value
   struct, like `core`'s `Unit`, has no storage. *)
let rec ty st span (t : Tty.t) : Nodes.Ty.t =
  match t with
  | Tty.Intrinsic { namespace = "primitives"; name; args = [] } -> (
      match name with
      | "Unit" -> Nodes.Ty.Void
      | "Bool" -> Nodes.Ty.I1
      | "Int" | "I64" -> Nodes.Ty.I64
      | "Float" -> Nodes.Ty.F64
      | "String" -> Nodes.Ty.View
      | _ -> unhandled span t)
  | Tty.Named ({ package; name }, []) -> (
      match Hashtbl.find_opt st.types (package, name) with
      | Some (T.Decl.Struct [], false) -> Nodes.Ty.Void
      | Some (T.Decl.Struct [ (_, member) ], false) -> ty st span member
      | _ -> unhandled span t)
  | _ -> unhandled span t

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

let rec expr st ctx (e : T.Expr.t) : Expr.t =
  let span = e.T.Expr.span in
  match e.T.Expr.node with
  | T.Expr.Var (T.Name_ref.Local l) -> (
      match lookup ctx span l with
      | Slot id -> { Expr.node = Expr.Local id; ty = ty st span l.T.Local.ty }
      | Literal _ | Code _ -> refuse span "lowering does not read this parameter as a value")
  | T.Expr.Bool_lit b -> { Expr.node = Expr.Bool b; ty = Nodes.Ty.I1 }
  | T.Expr.Construct { ctor = { owner = S.Intrinsic spelling; _ }; args; handler = None } ->
      primitive ctx span spelling args
  | T.Expr.Coerce { ctor = { owner = S.Intrinsic spelling; _ }; value } ->
      primitive ctx span spelling [ T.Arg.Value value ]
  | T.Expr.Construct { ctor = { owner = S.Declared id; instance = []; _ }; args; handler = None }
  | T.Expr.Call { callee = { owner = S.Declared id; instance = []; _ }; args; handler = None } ->
      call st ctx span id args e.T.Expr.ty
  | T.Expr.Coerce { ctor = { owner = S.Declared id; instance = []; _ }; value } ->
      call st ctx span id [ T.Arg.Value value ] e.T.Expr.ty
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
  | T.Expr.Op { op; impl = { owner; instance = []; _ }; left; right; swapped; handler = None } ->
      let t = ty st span e.T.Expr.ty in
      let apply l r =
        match owner with
        | S.Intrinsic _ ->
            { Expr.node = Expr.Binary { op = binop op; left = l; right = r }; ty = t }
        | S.Declared id -> (
            match Hashtbl.find_opt st.verbs id with
            | Some v when not (expands v) ->
                { Expr.node = Expr.Call { fn = symbol st v; args = [ l; r ] }; ty = t }
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
  | T.Expr.Flip { impl = { owner = S.Declared id; instance = []; _ }; value; handler = None } ->
      call st ctx span id [ T.Arg.Value value ] e.T.Expr.ty
  (* A value struct around one member is that member (L5), so reading the
     member is reading the struct, and building the struct is building the
     member. *)
  | T.Expr.Field { target; _ } -> { (expr st ctx target) with ty = ty st span e.T.Expr.ty }
  | T.Expr.Init [] -> { Expr.node = Expr.Unit; ty = Nodes.Ty.Void }
  | T.Expr.Init [ f ] -> { (expr st ctx f.T.Field_value.value) with ty = ty st span e.T.Expr.ty }
  | _ -> refuse span "lowering does not handle this expression yet"

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
          body = [ let_a; let_b; Stat.Assign { id = result; value = combine a b } ];
          result = Some result;
        };
    ty = t;
  }

and call st ctx span id args ret : Expr.t =
  match Hashtbl.find_opt st.verbs id with
  | None -> refuse span "lowering does not handle a call to this verb yet"
  | Some v when expands v -> expand st ctx span v args ret
  | Some v ->
      if v.signature.S.is_mut then refuse span "lowering does not pass a `mut` subject yet";
      let args =
        List.map
          (function
            | T.Arg.Value a -> expr st ctx a
            | T.Arg.Block _ -> refuse span "lowering does not expand block arguments here")
          args
      in
      { Expr.node = Expr.Call { fn = symbol st v; args }; ty = ty st span ret }

(* L11. A parameter is bound to what it stands for in the body: a block
   argument to its code, a literal to itself, the subject to the caller's
   place, and any other argument to a new slot holding its value (L6). *)
and expand st ctx span v args ret =
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
           | T.Arg.Value a, Tty.Concept (Tty.Block _) -> (
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
               | Slot id ->
                   bind p (Slot id);
                   []
               | _ -> refuse span "lowering expected a place here")
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
  let inner = { env; exit = Leave { label; result }; expanding = v.decl :: ctx.expanding } in
  match binds @ block st inner v.body with
  (* A body that only returns a value is that value. *)
  | [ Stat.Assign { id; value }; Stat.Leave l ] when Some id = result && l = label -> value
  | [ Stat.Eval value; Stat.Leave l ] when result = None && l = label -> value
  | body -> { Expr.node = Expr.Expand { label; body; result }; ty = t }

and block st ctx (b : T.Block.t) = List.concat_map (stat st ctx) b.T.Block.stats

(* A block argument's code, where it was written. *)
and code st ctx span (arg : T.Arg.t) =
  match arg with
  | T.Arg.Block b -> block st ctx b
  | T.Arg.Value { T.Expr.node = T.Expr.Var (T.Name_ref.Local l); _ } -> (
      match lookup ctx span l with
      | Code c -> block st c.ctx c.block
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
  | T.Stat.Assign { target = { T.Expr.node = T.Expr.Var (T.Name_ref.Local l); _ }; value } -> (
      match lookup ctx span l with
      | Slot id -> [ Stat.Assign { id; value = expr st ctx value } ]
      | _ -> refuse span "lowering expected a place here")
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
      | _ -> refuse span (Printf.sprintf "lowering does not handle `%s` yet" spelling))
  | T.Stat.Expr e -> [ Stat.Eval (expr st ctx e) ]
  | T.Stat.Return e -> (
      let value = expr st ctx e in
      match ctx.exit with
      | Function -> [ Stat.Return value ]
      | Leave { label; result = Some id } -> [ Stat.Assign { id; value }; Stat.Leave label ]
      | Leave { label; result = None } -> [ Stat.Eval value; Stat.Leave label ])
  | _ -> refuse span "lowering does not handle this statement yet"

let func st (v : verb) : Func.t =
  let span = v.body.T.Block.span in
  st.next <- 0;
  let env = Hashtbl.create 16 in
  let params =
    List.map
      (fun (p : T.Local.t) ->
        let id = fresh st in
        Hashtbl.replace env p.T.Local.id (Slot id);
        (id, ty st p.T.Local.span p.T.Local.ty))
      v.params
  in
  let ctx = { env; exit = Function; expanding = [] } in
  {
    Func.symbol = symbol st v;
    params;
    ret = ty st span v.signature.S.ret;
    body = block st ctx v.body;
  }

(* ---------------------------------------------------------------------- *)
(* Programs                                                               *)
(* ---------------------------------------------------------------------- *)

let program (p : T.Program.t) =
  let st =
    {
      verbs = Hashtbl.create 64;
      types = Hashtbl.create 64;
      symbols = Hashtbl.create 64;
      pending = Queue.create ();
      next = 0;
    }
  in
  List.iter
    (fun (pkg : T.Package.t) ->
      List.iter
        (fun (d : T.Decl.t) ->
          match d.T.Decl.node with
          | T.Decl.Type { name; params = []; reference; definition } ->
              Hashtbl.replace st.types (pkg.T.Package.name, name) (definition, reference)
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
        let entry = symbol st main in
        (* In the order calls first reach them, `main` first. *)
        let rec drain acc =
          match Queue.take_opt st.pending with
          | None -> List.rev acc
          | Some v -> drain (func st v :: acc)
        in
        Ok { Program.funcs = drain []; entry }
  with Refused problem -> Error problem
