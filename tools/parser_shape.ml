let rec expr_shape (expr : Cst.Nodes.Expr.t) =
  match expr with
  | Cst.Nodes.Expr.BoolLit _ -> "bool"
  | Cst.Nodes.Expr.NameExpr _ -> "name"
  | Cst.Nodes.Expr.DotAccess { target; _ } -> "dot(" ^ expr_shape target ^ ")"
  | Cst.Nodes.Expr.Parenthized inner -> "paren(" ^ expr_shape inner ^ ")"
  | Cst.Nodes.Expr.VerbCall (Cst.Nodes.Verb_call.Func { callee; _ }) ->
      "call(" ^ expr_shape callee ^ ")"
  | Cst.Nodes.Expr.VerbCall (Cst.Nodes.Verb_call.Flip { value; _ }) ->
      "flip(" ^ expr_shape value ^ ")"
  | Cst.Nodes.Expr.FuncLambda {
      body = Cst.Nodes.Body.Shorthand body;
      _;
    } ->
      "lambda(" ^ expr_shape body ^ ")"
  | _ -> "other"

let abort_expr (package : Cst.Nodes.Package.t) =
  match package.decls with
  | [ Cst.Nodes.Decl.Verb
        (Cst.Nodes.Verb_decl.Func {
          body = Cst.Nodes.Body.Longhand [ Cst.Nodes.Stat.Abort expr ];
          _;
        }) ] ->
      expr
  | _ -> failwith "expected one function containing one abort statement"

let () =
  if Array.length Sys.argv <> 2 then begin
    prerr_endline "usage: parser_shape SOURCE";
    exit 2
  end;
  match Cst.parse "<parser-grouping-test>" Sys.argv.(1) with
  | Ok package -> print_endline (expr_shape (abort_expr package))
  | Error message ->
      prerr_string message;
      exit 1
