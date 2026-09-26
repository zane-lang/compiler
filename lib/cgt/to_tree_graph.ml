(* The CGT as a tree to print, the `--cgt` view. Every expression shows the
   machine type it has. *)

open Tree_graph
open Nodes

let rec expr (e : Expr.t) =
  let typed s = Leaf (s ^ " : " ^ Ty.to_string e.Expr.ty) in
  let call title fn args =
    group title
      (fields
         [ ("type", Leaf (Ty.to_string e.Expr.ty)); ("fn", Leaf fn); ("args", map_seq expr args) ])
  in
  match e.Expr.node with
  | Expr.Int i -> typed (Int64.to_string i)
  | Expr.Float f -> typed (Printf.sprintf "%h" f)
  | Expr.Bool b -> typed (string_of_bool b)
  | Expr.Text s -> typed (Printf.sprintf "%S" s)
  | Expr.Unit -> typed "unit"
  | Expr.Local id -> typed (Printf.sprintf "local #%d" id)
  | Expr.Call { fn; args } -> call "call" fn args
  | Expr.Runtime { fn; args } -> call "runtime" fn args

let stat = function
  | Stat.Let { id; value } ->
      group "let" (fields [ ("local", Leaf (Printf.sprintf "#%d" id)); ("value", expr value) ])
  | Stat.Eval e -> group "eval" (expr e)
  | Stat.Return e -> group "return" (expr e)

let func (f : Func.t) =
  group "func"
    (fields
       [
         ("symbol", Leaf f.Func.symbol);
         ( "params",
           map_seq
             (fun (id, t) -> Leaf (Printf.sprintf "local #%d : %s" id (Ty.to_string t)))
             f.Func.params );
         ("ret", Leaf (Ty.to_string f.Func.ret));
         ("body", map_seq stat f.Func.body);
       ])

let program (p : Program.t) =
  group "program"
    (fields [ ("entry", Leaf p.Program.entry); ("funcs", map_seq func p.Program.funcs) ])
