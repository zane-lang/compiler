(* Literals, lowered to CGT values. *)

module T = Tst.Nodes
open Nodes
open State
open Type_layout

(* The spec names no escapes (lexical.md); the lexer keeps a backslash and the
   character after it together, and these are the ones lowering decodes
   (docs/design/lowering.md §9). Any other pair stands for itself. *)
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
  | None -> Diagnostic.bug ~span (Printf.sprintf "lowering found no slot for `%s`" l.T.Local.name)

(* A literal, read through the concept parameters it was passed on by. A
   number parameter read in a body is the number its instance was given
   (generics.md §3.5), which is an integer literal. *)
let rec literal_of ctx (e : T.Expr.t) =
  match e.T.Expr.node with
  | T.Expr.Var (T.Name_ref.Local l) -> (
      match lookup ctx e.T.Expr.span l with
      | Literal lit -> literal_of ctx lit
      | _ -> e)
  | T.Expr.Var (T.Name_ref.Number_param { value = Tst.Ty.Known n; _ }) ->
      { e with T.Expr.node = T.Expr.Integer_lit (string_of_int n) }
  | _ -> e

(* A numeric literal's digits, without the `'` that only separates groups of
   them (docs/spec-divergences.md §8). *)
let digits s = String.concat "" (String.split_on_char '\'' s)

(* A storage primitive's constructor embeds its literal (types.md §2.7). *)
let literal ctx span name (arg : T.Expr.t) : Expr.t =
  match (name, (literal_of ctx arg).T.Expr.node) with
  | "I64", T.Expr.Integer_lit s -> (
      match Int64.of_string_opt (digits s) with
      | Some i -> { Expr.node = Expr.Int i; ty = Nodes.Ty.I64 }
      | None -> refuse span (Printf.sprintf "`%s` is out of range for `@primitives$I64`" s))
  | "I32", T.Expr.Integer_lit s -> (
      match Int32.of_string_opt (digits s) with
      | Some i -> { Expr.node = Expr.Int (Int64.of_int32 i); ty = Nodes.Ty.I32 }
      | None -> refuse span (Printf.sprintf "`%s` is out of range for `@primitives$I32`" s))
  | ("F64" | "F32"), T.Expr.Decimal_lit s ->
      let ty = if name = "F32" then Nodes.Ty.F32 else Nodes.Ty.F64 in
      let value = float_of_string (digits s) in
      let value = if ty = Nodes.Ty.F32 then Scalar.single value else value in
      if Float.is_finite value then { Expr.node = Expr.Float value; ty }
      else refuse span (Printf.sprintf "`%s` is out of range for `@primitives$%s`" s name)
  | "String", T.Expr.Text_lit s -> { Expr.node = Expr.Text (unescape s); ty = Nodes.Ty.Handle }
  | _ -> Diagnostic.bug ~span (Printf.sprintf "lowering: `@primitives$%s` of something not its literal" name)
