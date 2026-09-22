(* Whether every statement agrees with the rules about where it ends.

   The rule is that a `;` ends a statement, unless the statement ends in a `}`
   -- then that brace ends it and a `;` would mark nothing (lexical.md §6.3).
   The grammar carries the first half: every statement is closed by one of the
   two, so a missing `;` never reaches here. What it still admits is a `;`
   after a closing brace, and a trailing argument's `}` with something written
   after it; each of those has a single parse, so [Parser] records it on the
   statement and this walk reports it.

   It records rather than raises because the parser is GLR: an action runs on
   every branch that is live at the time, including ones that lose a token
   later. Raising there ends the parse, not the branch. Walking the finished
   tree has neither problem: the branches that lost are gone, and what is left
   is what was really parsed.

   That needs a finished tree, which is also why a missing `;` is the grammar's
   to reject rather than this walk's. A statement allowed to end without one
   could end early, the next could open with `[` or `(`, and
   `abort false[]();` would have two complete parses -- the parser stops before
   there is a tree to walk. *)

let message (defect : Nodes.Statement_defect.t) =
  match defect with
  | Nodes.Statement_defect.Stray_semicolon ->
      "a statement ending in `}` is closed by that brace and takes no `;`"
  | Nodes.Statement_defect.Continued_trailing_argument ->
      "a trailing argument ends the statement, so nothing may continue it; \
       parenthesize the call to go on using its value"

(* The first defective statement in written order, if any. Reporting one is
   enough: each of these is a local property, so a second is not explained by
   the first and will be found on the next run. *)
let rec first_in_statements (statements : Nodes.Statement.t list) =
  match statements with
  | [] -> None
  | statement :: rest -> (
      match statement.Nodes.Statement.defect with
      | Some found -> Some found
      | None -> (
          match in_stat statement.Nodes.Statement.stat with
          | Some found -> Some found
          | None -> first_in_statements rest))

(* A statement's own mark is checked by the caller; this looks inside it, since
   a block argument or a verb body holds statements of its own. *)
and in_stat (stat : Nodes.Stat.t) =
  match stat.Nodes.Stat.node with
  | Nodes.Stat.VerbCall call | Nodes.Stat.Spawn call -> in_verb_call call
  | Nodes.Stat.Decl decl -> in_decl decl
  | Nodes.Stat.Assign { target; value } -> first_of [ target; value ]
  | Nodes.Stat.Abort value | Nodes.Stat.Ret value | Nodes.Stat.Resolve value ->
      in_expr value

and first_of exprs =
  List.fold_left
    (fun found expr -> match found with Some _ -> found | None -> in_expr expr)
    None exprs

and in_expr (expr : Nodes.Expr.t) =
  match expr.Nodes.Expr.node with
  | Nodes.Expr.VerbCall call | Nodes.Expr.Spawn call -> in_verb_call call
  | Nodes.Expr.FuncLambda { body; _ } -> in_body body
  | Nodes.Expr.MethLambda { body; _ } -> in_body body
  | Nodes.Expr.Match { scrutinees; arms; abort_handle; _ } -> (
      match first_of scrutinees with
      | Some found -> Some found
      | None -> (
          match
            List.fold_left
              (fun found (arm : Nodes.Match_arm.t) ->
                match found with
                | Some _ -> found
                | None -> in_body arm.Nodes.Match_arm.body)
              None arms
          with
          | Some found -> Some found
          | None -> in_abort_handle abort_handle))
  | Nodes.Expr.Pipe { callee; value; abort_handle } -> (
      match first_of [ callee; value ] with
      | Some found -> Some found
      | None -> in_abort_handle abort_handle)
  | Nodes.Expr.MethodTarget { callee; this; _ } -> first_of [ callee; this ]
  | Nodes.Expr.DotAccess { target; _ } -> in_expr target
  | Nodes.Expr.Subscript { target; args } -> first_of (target :: args)
  | Nodes.Expr.CollectionLit items -> first_of items
  | Nodes.Expr.MapLit entries ->
      first_of (List.concat_map (fun (key, value) -> [ key; value ]) entries)
  | Nodes.Expr.Init fields -> in_field_args fields
  | Nodes.Expr.Ref value | Nodes.Expr.Parenthized value -> in_expr value
  | Nodes.Expr.IntLit _ | Nodes.Expr.FloatLit _ | Nodes.Expr.StrLit _
  | Nodes.Expr.BoolLit _ | Nodes.Expr.NameExpr _ | Nodes.Expr.TypeMember _
  | Nodes.Expr.TypeValue _ ->
      None

and in_field_args (fields : Nodes.Field_arg.t list) =
  first_of (List.filter_map (fun (f : Nodes.Field_arg.t) -> f.value) fields)

and in_call_args (args : Nodes.Call_arg.t list) =
  List.fold_left
    (fun found (arg : Nodes.Call_arg.t) ->
      match found with
      | Some _ -> found
      | None -> (
          match arg.Nodes.Call_arg.node with
          | Nodes.Call_arg.Value value -> in_expr value
          | Nodes.Call_arg.Block statements -> first_in_statements statements))
    None args

and in_constructor_args (args : Nodes.Constructor_args.t) =
  match args.Nodes.Constructor_args.node with
  | Nodes.Constructor_args.Positional args -> in_call_args args
  | Nodes.Constructor_args.Fields fields -> in_field_args fields

and in_verb_call (call : Nodes.Verb_call.t) =
  match call.Nodes.Verb_call.node with
  | Nodes.Verb_call.Func { callee; args; abort_handle; _ } -> (
      match in_expr callee with
      | Some found -> Some found
      | None -> (
          match in_call_args args with
          | Some found -> Some found
          | None -> in_abort_handle abort_handle))
  | Nodes.Verb_call.Meth { callee; this; args; abort_handle; _ } -> (
      match first_of [ callee; this ] with
      | Some found -> Some found
      | None -> (
          match in_call_args args with
          | Some found -> Some found
          | None -> in_abort_handle abort_handle))
  | Nodes.Verb_call.Constructor { args; abort_handle; _ } -> (
      match in_constructor_args args with
      | Some found -> Some found
      | None -> in_abort_handle abort_handle)
  | Nodes.Verb_call.Op { left; right; abort_handle; _ } -> (
      match first_of [ left; right ] with
      | Some found -> Some found
      | None -> in_abort_handle abort_handle)
  | Nodes.Verb_call.Flip { value; abort_handle } -> (
      match in_expr value with
      | Some found -> Some found
      | None -> in_abort_handle abort_handle)

and in_abort_handle (handle : Nodes.Abort_handle.t option) =
  match handle with
  | None -> None
  | Some { Nodes.Abort_handle.node = Nodes.Abort_handle.Shorthand value; _ } ->
      in_expr value
  | Some { Nodes.Abort_handle.node = Nodes.Abort_handle.Longhand { body; _ }; _ } ->
      in_body body

and in_body (body : Nodes.Body.t) =
  match body.Nodes.Body.node with
  | Nodes.Body.Shorthand value -> in_expr value
  | Nodes.Body.Longhand statements -> first_in_statements statements

and in_decl (decl : Nodes.Decl.t) =
  match decl.Nodes.Decl.node with
  | Nodes.Decl.Package _ | Nodes.Decl.Import _ | Nodes.Decl.Type _
  | Nodes.Decl.Alias _ ->
      None
  | Nodes.Decl.Var { value; _ } -> in_expr value
  | Nodes.Decl.VarShorthand { args; _ } -> in_constructor_args args
  | Nodes.Decl.EnumMap { entries; _ } -> first_of (List.map snd entries)
  | Nodes.Decl.Verb verb -> in_verb_decl verb

and in_verb_decl (verb : Nodes.Verb_decl.t) =
  match verb.Nodes.Verb_decl.node with
  | Nodes.Verb_decl.Func { body; _ }
  | Nodes.Verb_decl.Meth { body; _ }
  | Nodes.Verb_decl.Op { body; _ }
  | Nodes.Verb_decl.Flip { body; _ } ->
      in_body body
  | Nodes.Verb_decl.Constructor { params; body; _ } -> (
      match in_constructor_params params with
      | Some found -> Some found
      | None -> in_body body)
  | Nodes.Verb_decl.Subscript { value; _ } -> in_expr value

and in_constructor_params (params : Nodes.Constructor_params.t) =
  match params.Nodes.Constructor_params.node with
  | Nodes.Constructor_params.Positional _ -> None
  | Nodes.Constructor_params.Fields fields ->
      first_of
        (List.filter_map
           (fun (f : Nodes.Constructor_field.t) -> f.default)
           fields)

(* [Ok ()] when every statement in the package ends the way its shape calls
   for. *)
let check (package : Nodes.Package.t) =
  match
    List.fold_left
      (fun found decl ->
        match found with Some _ -> found | None -> in_decl decl)
      None package.Nodes.Package.decls
  with
  | None -> Ok ()
  | Some (defect, position) -> Error (message defect, position)
