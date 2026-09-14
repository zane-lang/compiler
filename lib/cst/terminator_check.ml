(* Whether every statement carries the terminator its shape calls for.

   The rule is that a `;` ends a statement, unless the statement ends in a `}`
   -- then that brace ends it and a `;` would mark nothing. Which of the two a
   statement needs is a property of its tail, and the grammar has to choose
   whether to end the statement before it can see that tail: after
   `ran Bool = if(ready)` the next token decides, and a `{` there continues the
   call rather than starting anything.

   So the grammar admits both spellings and [Parser] records the mismatch on
   each statement instead of rejecting it. It records rather than raises
   because the parser is GLR: an action runs on every branch that is live at
   the time, and the branch that ends the statement early is live on input that
   parses perfectly well a token later. Raising there ends the parse, not the
   branch -- which is what made a whole test suite fail on readings none of
   those programs kept.

   Walking the finished tree has neither problem: the branches that lost are
   gone, and what is left is what was really parsed. *)

let message (error : Nodes.Terminator_error.t) =
  match error with
  | Nodes.Terminator_error.Stray_semicolon ->
      "a statement ending in `}` is closed by that brace and takes no `;`"
  | Nodes.Terminator_error.Missing_semicolon ->
      "a statement not ending in `}` needs a `;`"

(* The first badly terminated statement in written order, if any. Reporting one
   is enough: the terminator is a local property, so a second is not explained
   by the first and will be found on the next run. *)
let rec first_in_statements (statements : Nodes.Statement.t list) =
  match statements with
  | [] -> None
  | statement :: rest -> (
      match statement.Nodes.Statement.bad_terminator with
      | Some found -> Some found
      | None -> (
          match in_stat statement.Nodes.Statement.stat with
          | Some found -> Some found
          | None -> first_in_statements rest))

(* A statement's own mark is checked by the caller; this looks inside it, since
   a block argument or a verb body holds statements of its own. *)
and in_stat (stat : Nodes.Stat.t) =
  match stat with
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
  match expr with
  | Nodes.Expr.VerbCall call | Nodes.Expr.Spawn call -> in_verb_call call
  | Nodes.Expr.FuncLambda { body; _ } -> in_body body
  | Nodes.Expr.MethLambda { body; _ } -> in_body body
  | Nodes.Expr.Match { scrutinees; arms; abort_handle } -> (
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
  | Nodes.Expr.Logic { left; right; _ } -> first_of [ left; right ]
  | Nodes.Expr.MethodTarget { callee; this; _ } -> first_of [ callee; this ]
  | Nodes.Expr.DotAccess { target; _ } -> in_expr target
  | Nodes.Expr.Subscript { target; args } -> first_of (target :: args)
  | Nodes.Expr.CollectionLit items -> first_of items
  | Nodes.Expr.MapLit entries ->
      first_of (List.concat_map (fun (key, value) -> [ key; value ]) entries)
  | Nodes.Expr.Init fields -> in_field_args fields
  | Nodes.Expr.Ref value | Nodes.Expr.Parenthized value -> in_expr value
  | Nodes.Expr.IntLit _ | Nodes.Expr.FloatLit _ | Nodes.Expr.StrLit _
  | Nodes.Expr.BoolLit _ | Nodes.Expr.NameExpr _ | Nodes.Expr.TypeMember _ ->
      None

and in_field_args (fields : Nodes.Field_arg.t list) =
  first_of (List.filter_map (fun (f : Nodes.Field_arg.t) -> f.value) fields)

and in_call_args (args : Nodes.Call_arg.t list) =
  List.fold_left
    (fun found (arg : Nodes.Call_arg.t) ->
      match found with
      | Some _ -> found
      | None -> (
          match arg with
          | Nodes.Call_arg.Value value -> in_expr value
          | Nodes.Call_arg.Block statements -> first_in_statements statements))
    None args

and in_constructor_args (args : Nodes.Constructor_args.t) =
  match args with
  | Nodes.Constructor_args.Positional args -> in_call_args args
  | Nodes.Constructor_args.Fields fields -> in_field_args fields

and in_verb_call (call : Nodes.Verb_call.t) =
  match call with
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
  | Some (Nodes.Abort_handle.Shorthand value) -> in_expr value
  | Some (Nodes.Abort_handle.Longhand { body; _ }) -> in_body body

and in_body (body : Nodes.Body.t) =
  match body with
  | Nodes.Body.Shorthand value -> in_expr value
  | Nodes.Body.Longhand statements -> first_in_statements statements

and in_decl (decl : Nodes.Decl.t) =
  match decl with
  | Nodes.Decl.Package _ | Nodes.Decl.Import _ | Nodes.Decl.Type _
  | Nodes.Decl.Alias _ ->
      None
  | Nodes.Decl.Var { value; _ } -> in_expr value
  | Nodes.Decl.VarShorthand { args; _ } -> in_constructor_args args
  | Nodes.Decl.EnumMap { entries; _ } -> first_of (List.map snd entries)
  | Nodes.Decl.Verb verb -> in_verb_decl verb

and in_verb_decl (verb : Nodes.Verb_decl.t) =
  match verb with
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
  match params with
  | Nodes.Constructor_params.Positional _ -> None
  | Nodes.Constructor_params.Fields fields ->
      first_of
        (List.filter_map
           (fun (f : Nodes.Constructor_field.t) -> f.default)
           fields)

(* [Ok ()] when every statement in the package is terminated as its shape
   calls for. *)
let check (package : Nodes.Package.t) =
  match
    List.fold_left
      (fun found decl ->
        match found with Some _ -> found | None -> in_decl decl)
      None package.Nodes.Package.decls
  with
  | None -> Ok ()
  | Some (error, position) -> Error (message error, position)
