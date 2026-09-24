(* Where a statement ends, and whether it was spelled to match.

   Two questions about the tail of a statement's tree -- does it close with a
   brace, and does it end with a trailing argument that something then
   continued past -- and the constructors that record the answers on the
   statement node.

   Distinct from [Statement_check], which walks the finished CST and reports
   the defects recorded here: this module decides the shape while the tree is
   still being built, that one reads the marks off the tree that survived. *)

(* The span type lives below the stages, in [Source], because a source
   location is not CST-specific: SST and everything after it point at the same
   text. Aliased rather than spelled out at each mention. *)
module Span = Source.Span

(* Does this statement's last token close a brace?

   A statement ends with `;`, unless it ends with a `}` -- then that brace ends
   it and a `;` after it would mark nothing. Which of the two a statement takes
   is therefore a property of its final token, which is a property of the
   shape at the tail of its tree: every form below either closes with a brace
   itself or hands the question to whatever it ends with.

   The grammar decides this too -- a statement without a `;` must end in one of
   the `_braced` forms in [Parser] -- so the one place the answer is still read
   off the tree is a statement that was closed with a `;`: if it also ends in a
   brace, that `;` marks nothing. *)
let rec expr_ends_in_brace (value : Nodes.Expr.t) =
  match value.Nodes.Expr.node with
  | Nodes.Expr.Init _ | Nodes.Expr.MapLit _ -> true
  | Nodes.Expr.Match { abort_handle = Some handle; _ } ->
      abort_handle_ends_in_brace handle
  | Nodes.Expr.Match _ -> true
  | Nodes.Expr.VerbCall call | Nodes.Expr.Spawn call ->
      verb_call_ends_in_brace call
  | Nodes.Expr.FuncLambda { body; _ } -> body_ends_in_brace body
  | Nodes.Expr.MethLambda { body; _ } -> body_ends_in_brace body
  | Nodes.Expr.Ref value -> expr_ends_in_brace value
  | Nodes.Expr.DotAccess { abort_handle = Some handle; _ } ->
      abort_handle_ends_in_brace handle
  (* Closed by `)`, `]`, or the name itself. *)
  | Nodes.Expr.IntLit _ | Nodes.Expr.DecimalLit _ | Nodes.Expr.StrLit _
  | Nodes.Expr.BoolLit _ | Nodes.Expr.CollectionLit _ | Nodes.Expr.NameExpr _
  | Nodes.Expr.TypeMember _ | Nodes.Expr.TypeValue _ | Nodes.Expr.DotAccess _
  | Nodes.Expr.Subscript _ | Nodes.Expr.Parenthized _ ->
      false

and verb_call_ends_in_brace (call : Nodes.Verb_call.t) =
  match call.Nodes.Verb_call.node with
  | Nodes.Verb_call.Func { abort_handle = Some handle; _ }
  | Nodes.Verb_call.Meth { abort_handle = Some handle; _ }
  | Nodes.Verb_call.Constructor { abort_handle = Some handle; _ }
  | Nodes.Verb_call.Op { abort_handle = Some handle; _ }
  | Nodes.Verb_call.Flip { abort_handle = Some handle; _ } ->
      abort_handle_ends_in_brace handle
  (* A trailing argument's `}` is the call's last token; without one the `)` is. *)
  | Nodes.Verb_call.Func { trailing; _ } | Nodes.Verb_call.Meth { trailing; _ } ->
      trailing
  (* A field constructor call closes on the `}` of its own field body, which is
     why that form never trails: it has no `)` to elide. *)
  | Nodes.Verb_call.Constructor
      { args = { Nodes.Constructor_args.node = Nodes.Constructor_args.Fields _; _ }; _ } ->
      true
  | Nodes.Verb_call.Constructor { trailing; _ } -> trailing
  | Nodes.Verb_call.Op { right; _ } -> expr_ends_in_brace right
  | Nodes.Verb_call.Flip { value; _ } -> expr_ends_in_brace value

and abort_handle_ends_in_brace (handle : Nodes.Abort_handle.t) =
  match handle.Nodes.Abort_handle.node with
  | Nodes.Abort_handle.Shorthand value -> expr_ends_in_brace value
  | Nodes.Abort_handle.Longhand { body; _ } -> body_ends_in_brace body

and body_ends_in_brace (value : Nodes.Body.t) =
  match value.Nodes.Body.node with
  | Nodes.Body.Longhand _ -> true
  | Nodes.Body.Shorthand value -> expr_ends_in_brace value

(* A mould's delimiter is decided by its contents: named typed members take
   `{ }`, a flat list of names takes `[ ]`. Only the first closes a statement,
   so the shape has to be read rather than assumed from the value being
   moulded at all. *)
let moulded_ends_in_brace (moulded : Nodes.Moulded.t) =
  match moulded.Nodes.Moulded.mould.Nodes.Mould.node with
  | Nodes.Mould.Struct _ | Nodes.Mould.Variant _ -> true
  | Nodes.Mould.Enum _ -> false

let verb_decl_ends_in_brace (value : Nodes.Verb_decl.t) =
  match value.Nodes.Verb_decl.node with
  | Nodes.Verb_decl.Subscript { value; _ } -> expr_ends_in_brace value
  | Nodes.Verb_decl.Func { body; _ }
  | Nodes.Verb_decl.Meth { body; _ }
  | Nodes.Verb_decl.Op { body; _ }
  | Nodes.Verb_decl.Constructor { body; _ }
  | Nodes.Verb_decl.Flip { body; _ } ->
      body_ends_in_brace body

let decl_ends_in_brace (value : Nodes.Decl.t) =
  match value.Nodes.Decl.node with
  | Nodes.Decl.Package _ | Nodes.Decl.Import _ -> false
  | Nodes.Decl.Var { value; _ } -> expr_ends_in_brace value
  | Nodes.Decl.VarShorthand
      { args = { Nodes.Constructor_args.node = Nodes.Constructor_args.Fields _; _ }; _ } ->
      true
  | Nodes.Decl.VarShorthand { trailing; _ } -> trailing
  | Nodes.Decl.Type
      { value = { Nodes.Type_or_moulded.node = Nodes.Type_or_moulded.Moulded moulded; _ }; _ }
  | Nodes.Decl.Alias
      { value = { Nodes.Type_or_moulded.node = Nodes.Type_or_moulded.Moulded moulded; _ }; _ } ->
      moulded_ends_in_brace moulded
  (* Cast from a bare type expression, which closes on a name, `]`, `>` or `)`. *)
  | Nodes.Decl.Type _ | Nodes.Decl.Alias _ -> false
  (* Its entries are a `{ }` body. *)
  | Nodes.Decl.EnumMap _ -> true
  | Nodes.Decl.Verb verb -> verb_decl_ends_in_brace verb

(* Does this expression end with a call that closed itself with a trailing
   argument? That `}` ends the statement too, so nothing may follow it. *)
let rec ends_in_trailing_call (value : Nodes.Expr.t) =
  match value.Nodes.Expr.node with
  | Nodes.Expr.VerbCall { Nodes.Verb_call.node = call; _ } -> (
      match call with
      | Nodes.Verb_call.Func { abort_handle = None; trailing; _ }
      | Nodes.Verb_call.Meth { abort_handle = None; trailing; _ }
      | Nodes.Verb_call.Constructor { abort_handle = None; trailing; _ } ->
          trailing
      | Nodes.Verb_call.Op { right; abort_handle = None; _ } ->
          ends_in_trailing_call right
      | Nodes.Verb_call.Flip { value; abort_handle = None } ->
          ends_in_trailing_call value
      | _ -> false)
  | Nodes.Expr.Ref value -> ends_in_trailing_call value
  | _ -> false

(* Is a trailing argument's `}` written anywhere an operand continues past it?

   Only the left of a binary form can do that: the right is the tail, and
   whether the tail may end that way is the enclosing statement's question,
   answered where that statement is built. But the binary form itself can sit
   anywhere, so the whole of a statement's own expression is searched -- under
   a lambda's `=> expr` body, inside a match arm, in an argument, under a
   handler, and inside parentheses.

   Parentheses are searched even though they are also the escape: `(run() { })
   + Int(1)` is legal because the `)` closes the call before the operator sees
   it, which [ends_in_trailing_call] reports by not seeing through a
   [Parenthized]. `(run() { } + Int(1))` puts the operator *inside*, and is the
   same mistake wearing brackets.

   What is not searched is a nested statement -- a `{ }` body or block
   argument. Those carry their own marks, put there when they were built. *)
let rec continues_past_trailing (value : Nodes.Expr.t) =
  match value.Nodes.Expr.node with
  | Nodes.Expr.VerbCall call | Nodes.Expr.Spawn call ->
      verb_call_continues_past_trailing call
  | Nodes.Expr.Match { scrutinees; arms; abort_handle; _ } ->
      List.exists continues_past_trailing scrutinees
      || List.exists
           (fun (arm : Nodes.Match_arm.t) ->
             body_continues_past_trailing arm.Nodes.Match_arm.body)
           arms
      || handler_continues_past_trailing abort_handle
  | Nodes.Expr.FuncLambda { body; _ } | Nodes.Expr.MethLambda { body; _ } ->
      body_continues_past_trailing body
  | Nodes.Expr.Ref value | Nodes.Expr.Parenthized value ->
      continues_past_trailing value
  | Nodes.Expr.DotAccess { target; abort_handle; _ } ->
      continues_past_trailing target
      || handler_continues_past_trailing abort_handle
  | Nodes.Expr.Subscript { target; args } ->
      continues_past_trailing target || List.exists continues_past_trailing args
  | Nodes.Expr.CollectionLit items -> List.exists continues_past_trailing items
  | Nodes.Expr.MapLit entries ->
      List.exists
        (fun (key, value) ->
          continues_past_trailing key || continues_past_trailing value)
        entries
  | Nodes.Expr.Init fields -> field_args_continue_past_trailing fields
  | Nodes.Expr.IntLit _ | Nodes.Expr.DecimalLit _ | Nodes.Expr.StrLit _
  | Nodes.Expr.BoolLit _ | Nodes.Expr.NameExpr _ | Nodes.Expr.TypeMember _
  | Nodes.Expr.TypeValue _ ->
      false

and verb_call_continues_past_trailing (call : Nodes.Verb_call.t) =
  match call.Nodes.Verb_call.node with
  | Nodes.Verb_call.Op { left; right; abort_handle; _ } ->
      ends_in_trailing_call left || continues_past_trailing left
      || continues_past_trailing right
      || handler_continues_past_trailing abort_handle
  | Nodes.Verb_call.Flip { value; abort_handle } ->
      continues_past_trailing value
      || handler_continues_past_trailing abort_handle
  | Nodes.Verb_call.Func { callee; args; abort_handle; _ } ->
      continues_past_trailing callee
      || List.exists arg_continues_past_trailing args
      || handler_continues_past_trailing abort_handle
  | Nodes.Verb_call.Meth { callee; this; args; abort_handle; _ } ->
      continues_past_trailing callee || continues_past_trailing this
      || List.exists arg_continues_past_trailing args
      || handler_continues_past_trailing abort_handle
  | Nodes.Verb_call.Constructor { args; abort_handle; _ } ->
      constructor_args_continue_past_trailing args
      || handler_continues_past_trailing abort_handle

and arg_continues_past_trailing (arg : Nodes.Call_arg.t) =
  match arg.Nodes.Call_arg.node with
  | Nodes.Call_arg.Value value -> continues_past_trailing value
  (* A block argument holds statements, which carry their own marks. *)
  | Nodes.Call_arg.Block _ -> false

and constructor_args_continue_past_trailing (args : Nodes.Constructor_args.t) =
  match args.Nodes.Constructor_args.node with
  | Nodes.Constructor_args.Positional args ->
      List.exists arg_continues_past_trailing args
  | Nodes.Constructor_args.Fields fields ->
      field_args_continue_past_trailing fields

and field_args_continue_past_trailing (fields : Nodes.Field_arg.t list) =
  List.exists
    (fun (field : Nodes.Field_arg.t) ->
      match field.Nodes.Field_arg.value with
      | Some value -> continues_past_trailing value
      | None -> false)
    fields

and constructor_params_continue_past_trailing (params : Nodes.Constructor_params.t) =
  match params.Nodes.Constructor_params.node with
  | Nodes.Constructor_params.Positional _ -> false
  | Nodes.Constructor_params.Fields fields ->
      List.exists
        (fun (field : Nodes.Constructor_field.t) ->
          match field.Nodes.Constructor_field.default with
          | Some value -> continues_past_trailing value
          | None -> false)
        fields

and handler_continues_past_trailing (handle : Nodes.Abort_handle.t option) =
  match handle with
  | None -> false
  | Some { Nodes.Abort_handle.node = Nodes.Abort_handle.Shorthand value; _ } ->
      continues_past_trailing value
  | Some { Nodes.Abort_handle.node = Nodes.Abort_handle.Longhand { body; _ }; _ } ->
      body_continues_past_trailing body

(* A `{ }` body is a run of statements, each already marked when it was built;
   only a `=> expr` body is part of this statement's own expression. *)
and body_continues_past_trailing (value : Nodes.Body.t) =
  match value.Nodes.Body.node with
  | Nodes.Body.Longhand _ -> false
  | Nodes.Body.Shorthand value -> continues_past_trailing value

let verb_decl_continues_past_trailing (value : Nodes.Verb_decl.t) =
  match value.Nodes.Verb_decl.node with
  | Nodes.Verb_decl.Subscript { value; _ } -> continues_past_trailing value
  | Nodes.Verb_decl.Constructor { params; body; _ } ->
      constructor_params_continue_past_trailing params
      || body_continues_past_trailing body
  | Nodes.Verb_decl.Func { body; _ }
  | Nodes.Verb_decl.Meth { body; _ }
  | Nodes.Verb_decl.Op { body; _ }
  | Nodes.Verb_decl.Flip { body; _ } ->
      body_continues_past_trailing body

(* A declaration's own expression, for the same question. *)
let decl_continues_past_trailing (value : Nodes.Decl.t) =
  match value.Nodes.Decl.node with
  | Nodes.Decl.Var { value; _ } -> continues_past_trailing value
  | Nodes.Decl.VarShorthand { args; _ } ->
      constructor_args_continue_past_trailing args
  | Nodes.Decl.EnumMap { entries; _ } ->
      List.exists (fun (_, value) -> continues_past_trailing value) entries
  | Nodes.Decl.Verb verb -> verb_decl_continues_past_trailing verb
  | Nodes.Decl.Package _ | Nodes.Decl.Import _ | Nodes.Decl.Type _
  | Nodes.Decl.Alias _ ->
      false

(* Build a statement the grammar closed with a `;`, recording how it disagrees
   with the rules about where a statement ends, if it does.

   The grammar decides whether a statement needs its `;` -- a missing one is a
   parse error -- but it still admits one after a statement that ends in a `}`,
   where the brace has already closed it. That spelling has one parse, since no
   statement begins with a `;`, so it is marked here rather than refused there.

   None of this raises. An action here runs on every branch the GLR parser has
   live, and a branch that loses is still live when its actions run -- raising
   there would end the parse rather than the branch. [Statement_check] reads the
   mark off the tree that actually survived. *)
let statement ~ends_in_brace ~ends_at ~continued ~loc node =
  let defect =
    if continued then
      Some (Nodes.Statement_defect.Continued_trailing_argument, ends_at)
    else if ends_in_brace then
      Some (Nodes.Statement_defect.Stray_semicolon, ends_at)
    else None
  in
  let span = Span.of_loc loc in
  ({ Nodes.Statement.stat = { Nodes.Stat.node; span }; defect; span }
    : Nodes.Statement.t)

(* A `;`-closed statement whose tail is an expression. *)
let expr_statement ~ends_at ~loc build value =
  statement
    ~ends_in_brace:(expr_ends_in_brace value)
    ~ends_at ~loc
    ~continued:(continues_past_trailing value)
    (build value)

(* Closed by its own brace, so there was never a terminator to get wrong. The
   other question still stands: a trailing argument continued past its `}` can
   be written inside such a statement -- in an argument of the call that closed
   it, or in a constructor field's default -- and the rule does not bend for
   where the enclosing statement happens to end. *)
let braced_statement ~ends_at ~continued ~loc node =
  let defect =
    if continued then
      Some (Nodes.Statement_defect.Continued_trailing_argument, ends_at)
    else None
  in
  let span = Span.of_loc loc in
  ({ Nodes.Statement.stat = { Nodes.Stat.node; span }; defect; span }
    : Nodes.Statement.t)

(* Terminated by a `;` the grammar itself requires, so there was never a
   terminator to get wrong here either -- the parse fails without it rather
   than the tree carrying a defect to [Statement_check]. *)
let terminated_statement ~loc node =
  let span = Span.of_loc loc in
  ({ Nodes.Statement.stat = { Nodes.Stat.node; span }; defect = None; span }
    : Nodes.Statement.t)
