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
(* Types                                                                  *)
(* ---------------------------------------------------------------------- *)

(* L5: a storage primitive has a machine layout. *)
let ty span (t : Tty.t) : Nodes.Ty.t =
  match t with
  | Tty.Intrinsic { namespace = "primitives"; name; args = [] } -> (
      match name with
      | "Unit" -> Nodes.Ty.Void
      | "Bool" -> Nodes.Ty.I1
      | "Int" | "I64" -> Nodes.Ty.I64
      | "Float" -> Nodes.Ty.F64
      | "String" -> Nodes.Ty.View
      | _ -> refuse span (Printf.sprintf "lowering does not handle `%s` yet" (Tty.to_string t)))
  | _ -> refuse span (Printf.sprintf "lowering does not handle `%s` yet" (Tty.to_string t))

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

(* A storage primitive's constructor embeds its literal (types.md §2.7). *)
let literal span name (arg : T.Expr.t) : Expr.t =
  match (name, arg.T.Expr.node) with
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

type verb = { decl : int; signature : S.t; params : T.Local.t list; body : T.Block.t }

type state = {
  verbs : (int, verb) Hashtbl.t;
  (* Symbols already lowered or on their way, and the verbs still to lower. *)
  symbols : (int, string) Hashtbl.t;
  mutable pending : verb list;
}

let sanitize name =
  String.map (fun c -> match c with 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> c | _ -> '_') name

(* A verb's symbol names its declaration, so two overloads never share one. *)
let symbol st (v : verb) =
  match Hashtbl.find_opt st.symbols v.decl with
  | Some s -> s
  | None ->
      let s = Printf.sprintf "zane_%s_%d" (sanitize v.signature.S.name) v.decl in
      Hashtbl.replace st.symbols v.decl s;
      st.pending <- v :: st.pending;
      s

let rec expr st (e : T.Expr.t) : Expr.t =
  let span = e.T.Expr.span in
  match e.T.Expr.node with
  | T.Expr.Var (T.Name_ref.Local l) ->
      { Expr.node = Expr.Local l.T.Local.id; ty = ty span l.T.Local.ty }
  | T.Expr.Construct { ctor = { owner = S.Intrinsic spelling; _ }; args; handler = None } -> (
      let name =
        let prefix = "@primitives$" in
        let n = String.length prefix in
        if String.length spelling > n && String.sub spelling 0 n = prefix then
          String.sub spelling n (String.length spelling - n)
        else spelling
      in
      match (name, args) with
      | "Unit", [] -> { Expr.node = Expr.Unit; ty = Nodes.Ty.Void }
      | _, [ T.Arg.Value v ] -> literal span name v
      | _ -> refuse span (Printf.sprintf "lowering does not handle `%s` yet" spelling))
  | T.Expr.Call { callee = { owner = S.Intrinsic "@runtime$print"; _ }; args; handler = None }
    -> (
      (* The program has one console (effects.md §6.6), so the subject names
         nothing the runtime needs. *)
      match args with
      | [ T.Arg.Value _console; T.Arg.Value text ] ->
          {
            Expr.node = Expr.Runtime { fn = "zane_print"; args = [ expr st text ] };
            ty = Nodes.Ty.Void;
          }
      | _ -> refuse span "lowering does not handle this call to `print`")
  | T.Expr.Call { callee = { owner = S.Declared id; instance = []; _ }; args; handler = None }
    -> (
      match Hashtbl.find_opt st.verbs id with
      | Some v ->
          let args =
            List.map
              (function
                | T.Arg.Value a -> expr st a
                | T.Arg.Block _ -> refuse span "lowering does not expand block arguments yet")
              args
          in
          { Expr.node = Expr.Call { fn = symbol st v; args }; ty = ty span e.T.Expr.ty }
      | None -> refuse span "lowering does not handle a call to this verb yet")
  | _ -> refuse span "lowering does not handle this expression yet"

let stat st (s : T.Stat.t) : Stat.t =
  match s.T.Stat.node with
  | T.Stat.Expr e -> Stat.Eval (expr st e)
  | T.Stat.Return e -> Stat.Return (expr st e)
  | _ -> refuse s.T.Stat.span "lowering does not handle this statement yet"

let func st (v : verb) : Func.t =
  let span = v.body.T.Block.span in
  {
    Func.symbol = symbol st v;
    params =
      List.map (fun (p : T.Local.t) -> (p.T.Local.id, ty p.T.Local.span p.T.Local.ty)) v.params;
    ret = ty span v.signature.S.ret;
    body = List.map (stat st) v.body.T.Block.stats;
  }

(* ---------------------------------------------------------------------- *)
(* Programs                                                               *)
(* ---------------------------------------------------------------------- *)

let program (p : T.Program.t) =
  let st = { verbs = Hashtbl.create 64; symbols = Hashtbl.create 64; pending = [] } in
  List.iter
    (fun (pkg : T.Package.t) ->
      List.iter
        (fun (d : T.Decl.t) ->
          match d.T.Decl.node with
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
        let rec drain acc =
          match st.pending with
          | [] -> List.rev acc
          | v :: rest ->
              st.pending <- rest;
              drain (func st v :: acc)
        in
        Ok { Program.funcs = drain []; entry }
  with Refused problem -> Error problem
