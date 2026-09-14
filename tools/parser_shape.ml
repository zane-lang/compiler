let parts name shapes = name ^ "(" ^ String.concat ", " shapes ^ ")"

(* A block argument renders as [block] wherever it sits, so a shape says which
   call a block joined and in which position, which is the grouping question a
   trailing block raises. *)
let rec arg_shape (arg : Cst.Nodes.Call_arg.t) =
  match arg with
  | Cst.Nodes.Call_arg.Value value -> expr_shape value
  | Cst.Nodes.Call_arg.Block _ -> "block"

and expr_shape (expr : Cst.Nodes.Expr.t) =
  match expr with
  | Cst.Nodes.Expr.BoolLit _ -> "bool"
  | Cst.Nodes.Expr.NameExpr _ -> "name"
  | Cst.Nodes.Expr.TypeMember _ -> "type_member"
  | Cst.Nodes.Expr.DotAccess { target; _ } -> "dot(" ^ expr_shape target ^ ")"
  | Cst.Nodes.Expr.Parenthized inner -> "paren(" ^ expr_shape inner ^ ")"
  | Cst.Nodes.Expr.VerbCall (Cst.Nodes.Verb_call.Func { callee; args; _ }) ->
      parts "call" (expr_shape callee :: List.map arg_shape args)
  | Cst.Nodes.Expr.VerbCall
      (Cst.Nodes.Verb_call.Meth { callee; this; args; _ }) ->
      parts "meth" (expr_shape this :: expr_shape callee :: List.map arg_shape args)
  (* A constructor call renders its arguments for the same reason a function
     call does: a trailing block is the last of them, and the shape is what
     says it joined this call rather than something inside it. *)
  | Cst.Nodes.Expr.VerbCall (Cst.Nodes.Verb_call.Constructor { name; args; _ })
    ->
      let tag =
        match name.Cst.Nodes.Constructor_name.member with
        | Some _ -> "named_ctor"
        | None -> "ctor"
      in
      (match args with
      | Cst.Nodes.Constructor_args.Positional args ->
          parts tag (List.map arg_shape args)
      | Cst.Nodes.Constructor_args.Fields _ -> parts tag [ "fields" ])
  | Cst.Nodes.Expr.VerbCall (Cst.Nodes.Verb_call.Flip { value; _ }) ->
      "flip(" ^ expr_shape value ^ ")"
  | Cst.Nodes.Expr.FuncLambda {
      body = Cst.Nodes.Body.Shorthand body;
      _;
    } ->
      "lambda(" ^ expr_shape body ^ ")"
  (* A `{ }`-bodied lambda renders as [block] for the same reason a block
     argument does: `Foo() { ... }` is one of these and not a constructor call
     with a trailing block, and the shape is what says so. *)
  | Cst.Nodes.Expr.FuncLambda { body = Cst.Nodes.Body.Longhand _; _ } ->
      "lambda(block)"
  | Cst.Nodes.Expr.Spawn call ->
      "spawn(" ^ expr_shape (Cst.Nodes.Expr.VerbCall call) ^ ")"
  | Cst.Nodes.Expr.Match { scrutinees; _ } ->
      parts "match" (List.map expr_shape scrutinees)
  | Cst.Nodes.Expr.Ref value -> "ref(" ^ expr_shape value ^ ")"
  (* A map literal renders its entries in order, so a shape says whether a
     brace in argument position was read as a literal or as a block. *)
  | Cst.Nodes.Expr.MapLit entries ->
      parts "map"
        (List.concat_map
           (fun (key, value) -> [ expr_shape key; expr_shape value ])
           entries)
  | _ -> "other"

let abort_expr (package : Cst.Nodes.Package.t) =
  match package.decls with
  | [ Cst.Nodes.Decl.Verb
        (Cst.Nodes.Verb_decl.Func {
          body =
            Cst.Nodes.Body.Longhand
              [ { Cst.Nodes.Statement.stat = Cst.Nodes.Stat.Abort expr; _ } ];
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
