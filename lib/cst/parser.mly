%{
(* Node constructors, one per spanned module.

   Every action builds its node from a variant and the production's own [$loc],
   so each is written [expr $loc (Nodes.Expr.IntLit i)] rather than spelling the
   record out. They exist because the span is not optional: a node built without
   one does not typecheck, which is what keeps a production from quietly
   dropping the position it was reduced from. *)
(* Not called [name]: these are used from `%inline` rules, whose bodies are
   expanded into their callers, and a caller binding `name=...` would capture
   the reference. *)
let mk_name loc text = ({ Nodes.Name.text; span = Span.of_loc loc } : Nodes.Name.t)

let expr loc node = ({ Nodes.Expr.node; span = Span.of_loc loc } : Nodes.Expr.t)

let abort_handle_node loc node =
  ({ Nodes.Abort_handle.node; span = Span.of_loc loc } : Nodes.Abort_handle.t)

let call_arg loc node =
  ({ Nodes.Call_arg.node; span = Span.of_loc loc } : Nodes.Call_arg.t)

let constructor_args loc node =
  ({ Nodes.Constructor_args.node; span = Span.of_loc loc }
    : Nodes.Constructor_args.t)

let verb_call loc node =
  ({ Nodes.Verb_call.node; span = Span.of_loc loc } : Nodes.Verb_call.t)

let mould loc node = ({ Nodes.Mould.node; span = Span.of_loc loc } : Nodes.Mould.t)

let generic_arg loc node =
  ({ Nodes.Generic_arg.node; span = Span.of_loc loc } : Nodes.Generic_arg.t)

let verb_type loc node =
  ({ Nodes.Verb_type.node; span = Span.of_loc loc } : Nodes.Verb_type.t)

let type_expr loc node =
  ({ Nodes.Type_expr.node; span = Span.of_loc loc } : Nodes.Type_expr.t)

let param_type loc node =
  ({ Nodes.Param_type.node; span = Span.of_loc loc } : Nodes.Param_type.t)

let constructor_params loc node =
  ({ Nodes.Constructor_params.node; span = Span.of_loc loc }
    : Nodes.Constructor_params.t)

let stat loc node = ({ Nodes.Stat.node; span = Span.of_loc loc } : Nodes.Stat.t)

let body loc node = ({ Nodes.Body.node; span = Span.of_loc loc } : Nodes.Body.t)

let ret_type loc node =
  ({ Nodes.Ret_type.node; span = Span.of_loc loc } : Nodes.Ret_type.t)

let type_or_moulded loc node =
  ({ Nodes.Type_or_moulded.node; span = Span.of_loc loc }
    : Nodes.Type_or_moulded.t)

let verb_decl loc node =
  ({ Nodes.Verb_decl.node; span = Span.of_loc loc } : Nodes.Verb_decl.t)

let decl loc node = ({ Nodes.Decl.node; span = Span.of_loc loc } : Nodes.Decl.t)

let operator loc node =
  ({ Nodes.Operator.node; is_loose = false; span = Span.of_loc loc }
    : Nodes.Operator.t)

(* The same operator, written with its `'` prefix. Two constructors rather than
   a flag at each of the twenty call sites, so the ten loose productions are
   the only ones that say so. *)
let loose_operator loc node =
  ({ Nodes.Operator.node; is_loose = true; span = Span.of_loc loc }
    : Nodes.Operator.t)

let concept loc node =
  ({ Nodes.Concept.node; span = Span.of_loc loc } : Nodes.Concept.t)

let name_type loc node =
  ({ Nodes.Name_type.node; span = Span.of_loc loc } : Nodes.Name_type.t)

let name_expr loc node =
  ({ Nodes.Name_expr.node; span = Span.of_loc loc } : Nodes.Name_expr.t)

let import loc node =
  ({ Nodes.Import.node; span = Span.of_loc loc } : Nodes.Import.t)

let type_axis loc node =
  ({ Nodes.Type_axis.node; span = Span.of_loc loc } : Nodes.Type_axis.t)

let attach_abort_handle abort_handle span value =
  let attach (call : Nodes.Verb_call.t) =
    match call.Nodes.Verb_call.node with
    (* A trailing argument ends its statement, so nothing may continue the call
       past that `}` -- a handler included. The same call written with the
       argument inside the parentheses takes one. *)
    | Nodes.Verb_call.Func { trailing = true; _ }
    | Nodes.Verb_call.Meth { trailing = true; _ }
    | Nodes.Verb_call.Constructor { trailing = true; _ } ->
        raise
          (Parse_error.Rejected
             "a trailing argument ends the statement, so an abort handler \
              cannot follow it; write the argument inside the argument list")
    | Nodes.Verb_call.Func { callee; args; abort_handle = None; trailing } ->
        { call with
          Nodes.Verb_call.node =
            Nodes.Verb_call.Func {
              callee;
              args;
              abort_handle = Some abort_handle;
              trailing;
            } }
    | Nodes.Verb_call.Meth { callee; this; args; abort_handle = None; is_mut; trailing } ->
        { call with
          Nodes.Verb_call.node =
            Nodes.Verb_call.Meth {
              callee;
              this;
              args;
              abort_handle = Some abort_handle;
              is_mut;
              trailing;
            } }
    | Nodes.Verb_call.Constructor { name; args; abort_handle = None; trailing } ->
        { call with
          Nodes.Verb_call.node =
            Nodes.Verb_call.Constructor {
              name;
              args;
              abort_handle = Some abort_handle;
              trailing;
            } }
    | Nodes.Verb_call.Op { op; left; right; abort_handle = None } ->
        { call with
          Nodes.Verb_call.node =
            Nodes.Verb_call.Op {
              op;
              left;
              right;
              abort_handle = Some abort_handle;
            } }
    | Nodes.Verb_call.Flip { value; abort_handle = None } ->
        { call with
          Nodes.Verb_call.node =
            Nodes.Verb_call.Flip { value; abort_handle = Some abort_handle } }
    | _ ->
        raise
          (Parse_error.Rejected "an operation can only have one abort handler")
  in
  (* The handler is written to the right of the operation it handles, so the
     node it attaches to now ends later than it did when it was built. Each
     rebuilt node therefore takes the span the caller passes, which is the
     `expr abort_handle` production's own -- the operation through the handler.
     What is not rebuilt keeps the span it had. *)
  let rec loop span (value : Nodes.Expr.t) =
    match value.Nodes.Expr.node with
    | Nodes.Expr.VerbCall call ->
        { Nodes.Expr.node = Nodes.Expr.VerbCall (attach call); span }
    | Nodes.Expr.Spawn call ->
        { Nodes.Expr.node = Nodes.Expr.Spawn (attach call); span }
    | Nodes.Expr.Match ({ abort_handle = None; _ } as match_) ->
        {
          Nodes.Expr.node =
            Nodes.Expr.Match
              { match_ with Nodes.Match_expr.abort_handle = Some abort_handle; span };
          span;
        }
    | Nodes.Expr.Pipe { callee; value = piped; abort_handle = None } ->
        {
          Nodes.Expr.node =
            Nodes.Expr.Pipe
              { callee; value = piped; abort_handle = Some abort_handle };
          span;
        }
    | Nodes.Expr.Parenthized inner ->
        { Nodes.Expr.node = Nodes.Expr.Parenthized (loop span inner); span }
    | _ ->
        raise
          (Parse_error.Rejected
             "an abort handler must follow an abortable operation")
  in
  loop span value

let constructor_expr loc name args =
  expr loc
    (Nodes.Expr.VerbCall
       (verb_call loc
          (Nodes.Verb_call.Constructor
             { name; args; abort_handle = None; trailing = false })))

(* Does this statement's last token close a brace?

   A statement ends with `;`, unless it ends with a `}` -- then that brace ends
   it and a `;` after it would mark nothing. Which of the two a statement takes
   is therefore a property of its final token, which is a property of the
   shape at the tail of its tree: every form below either closes with a brace
   itself or hands the question to whatever it ends with.

   The grammar accepts a terminator either way and the check below rejects the
   spelling that does not match, rather than the language being split into
   brace-ending and non-brace-ending halves. A grammatical split would have to
   reach through every binary operator -- `a + match (e) { ... }` ends in a brace
   because its right operand does -- which means two copies of the expression
   grammar and two of every operator production. One function over the tree
   says the same thing once. *)
let rec expr_ends_in_brace (value : Nodes.Expr.t) =
  match value.Nodes.Expr.node with
  | Nodes.Expr.Init _ | Nodes.Expr.MapLit _ -> true
  | Nodes.Expr.Match { abort_handle = Some handle; _ } ->
      abort_handle_ends_in_brace handle
  | Nodes.Expr.Match _ -> true
  | Nodes.Expr.VerbCall call | Nodes.Expr.Spawn call ->
      verb_call_ends_in_brace call
  | Nodes.Expr.Pipe { abort_handle = Some handle; _ } ->
      abort_handle_ends_in_brace handle
  | Nodes.Expr.Pipe { value; _ } -> expr_ends_in_brace value
  | Nodes.Expr.FuncLambda { body; _ } -> body_ends_in_brace body
  | Nodes.Expr.MethLambda { body; _ } -> body_ends_in_brace body
  | Nodes.Expr.Ref value -> expr_ends_in_brace value
  (* Only ever a [Pipe]'s callee, which is never the tail of the statement. *)
  | Nodes.Expr.MethodTarget _ -> false
  (* Closed by `)`, `]`, or the name itself. *)
  | Nodes.Expr.IntLit _ | Nodes.Expr.FloatLit _ | Nodes.Expr.StrLit _
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

(* An `as` alias renames one member, and casing is what says whether a name is
   a type or a value, so a rename across the two classes would change what the
   name means rather than what it is spelled. The grammar admits either
   spelling on each side because both are ordinary names; only the pair is
   wrong. *)
let import_alias (member : Nodes.Import_member.t)
    (alias : Nodes.Import_member.t) =
  if member.Nodes.Import_member.is_type <> alias.Nodes.Import_member.is_type
  then
    raise
      (Parse_error.Rejected
         "an `as` alias has to keep the casing of the name it renames, since \
          an uppercase-initial name is a type and a lowercase one a value");
  alias

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
  | Nodes.Expr.Pipe { value; abort_handle = None; _ } ->
      ends_in_trailing_call value
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
  | Nodes.Expr.Pipe { callee; value; abort_handle } ->
      ends_in_trailing_call callee || continues_past_trailing callee
      || continues_past_trailing value
      || handler_continues_past_trailing abort_handle
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
  | Nodes.Expr.MethodTarget { callee; this; _ } ->
      continues_past_trailing callee || continues_past_trailing this
  | Nodes.Expr.DotAccess { target; _ } -> continues_past_trailing target
  | Nodes.Expr.Subscript { target; args } ->
      continues_past_trailing target || List.exists continues_past_trailing args
  | Nodes.Expr.CollectionLit items -> List.exists continues_past_trailing items
  | Nodes.Expr.MapLit entries ->
      List.exists
        (fun (key, value) ->
          continues_past_trailing key || continues_past_trailing value)
        entries
  | Nodes.Expr.Init fields -> field_args_continue_past_trailing fields
  | Nodes.Expr.IntLit _ | Nodes.Expr.FloatLit _ | Nodes.Expr.StrLit _
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

(* Build a statement, recording how it disagrees with the rules about where a
   statement ends, if it does.

   The terminator is the first of those: it disagrees exactly when the two are
   equal, since a statement ending in `}` is closed by that brace and takes no
   `;`, and one that does not end in `}` has nothing else to close it.

   None of this raises. An action here runs on every branch the GLR parser has
   live, and the branch that ends a statement one token before a `{` continues
   it is live on perfectly good input -- raising there would end the parse
   rather than the branch. [Statement_check] reads the mark off the tree that
   actually survived. *)
let statement ~ends_in_brace ~terminated ~ends_at ~continued ~loc node =
  let defect =
    if continued then
      Some (Nodes.Statement_defect.Continued_trailing_argument, ends_at)
    else if ends_in_brace <> terminated then None
    else if terminated then
      Some (Nodes.Statement_defect.Stray_semicolon, ends_at)
    else Some (Nodes.Statement_defect.Missing_semicolon, ends_at)
  in
  let span = Span.of_loc loc in
  ({ Nodes.Statement.stat = { Nodes.Stat.node; span }; defect; span }
    : Nodes.Statement.t)

(* A statement whose tail is an expression. *)
let expr_statement ~terminated ~ends_at ~loc build value =
  statement
    ~ends_in_brace:(expr_ends_in_brace value)
    ~terminated ~ends_at ~loc
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
%}

(*****************************)
(*     token definitions     *)
(*****************************)
%token <string> INT "43"
%token <string> FLOAT "8.647"
%token <string> STRING "\"john\""
%token <string> LIDENT "length"
%token <string> UIDENT "Int"

%token LPAREN      "("
%token RPAREN      ")"
%token COMMA       ","
%token LCURLY      "{"
%token RCURLY      "}"
%token LBRACKET    "["
%token RBRACKET    "]"
%token COLON       ":"
%token SEMICOLON   ";"
%token DOT         "."
%token EQUAL       "="
%token PLUS        "+"
%token MINUS       "-"
%token STAR        "*"
%token SLASH       "/"
%token PIPE        "|"
%token DOLLAR      "$"
%token HASH        "#"
%token AMPERSAND   "&"
%token AT          "@"
%token EXCL        "!"
%token QSTNMARK    "?"
%token QSTNQSTN    "??"
%token TILDE       "~"
%token THICK_ARROW "=>"
%token EQEQ        "=="
%token NOTEQ       "~="
%token LESSEQ      "<="
%token MOREEQ      ">="
%token LESS        "<"
%token MORE        ">"

(* The loose forms of operators.md §3.1: one token each, so the `'` must touch
   the operator it prefixes. *)
%token LOOSE_STAR   "'*"
%token LOOSE_SLASH  "'/"
%token LOOSE_PLUS   "'+"
%token LOOSE_MINUS  "'-"
%token LOOSE_EQEQ   "'=="
%token LOOSE_NOTEQ  "'~="
%token LOOSE_LESSEQ "'<="
%token LOOSE_MOREEQ "'>="
%token LOOSE_LESS   "'<"
%token LOOSE_MORE   "'>"

%token LTYPE       "type"
%token ALIAS       "alias"
%token UTYPE       "Type"
%token NUMBER      "Number"
%token STRUCT      "struct"
%token VARIANT     "variant"
%token ENUM        "enum"
%token PACKAGE     "package"
%token IMPORT      "import"
%token AS          "as"
%token IMPLICIT    "implicit"
%token INIT        "init"
%token MATCH       "match"
%token SPAWN       "spawn"
%token TRUE        "true"
%token FALSE       "false"
%token THIS        "this"
%token MUT         "mut"
%token ABORT       "abort"
%token RETURN      "return"
%token RESOLVE     "resolve"
%token EOF          "<eof>"

(* The precedence table of operators.md §3, loosest first -- which is Menhir's
   order, so the declarations below read as that table upside down. The numbered
   lines are that table exactly, and are every operator the language has. The
   unnumbered ones carry no level in the spec because they are not operators:
   they are abort handling and the postfix chain, placed where each has to be
   for the chain to thread. *)
%right THICK_ARROW
%left LOOSE_EQEQ LOOSE_NOTEQ LOOSE_LESSEQ LOOSE_MOREEQ LOOSE_LESS LOOSE_MORE  /* 8 */
%left LOOSE_PLUS LOOSE_MINUS                    /* 7 */
%left LOOSE_STAR LOOSE_SLASH                    /* 6 -- the loose tier, §3.1 */
%left EQEQ NOTEQ LESSEQ MOREEQ LESS MORE        /* 5 -- comparisons */
%left PLUS MINUS                                /* 4 */
%left STAR SLASH                                /* 3 */
%left PIPE                                      /* 2 -- pipe syntax */
%nonassoc QSTNMARK QSTNQSTN                    /* abort handling */
%nonassoc TILDE AMPERSAND                       /* 1 -- prefix ~, and & */
%left DOT                                       /* field access */
%left LBRACKET                                  /* subscript */
%left LPAREN                                    /* function application */

%start <Nodes.Package.t> package

(*************************)
(*     grammar rules     *)
(*************************)
%%

(* A package-scope declaration is not a statement and carries no terminator of
   its own: it ends where its own body, bracket, or expression ends. A `;`
   there would belong to nothing, since nothing follows a declaration that a
   terminator would have to be told apart from -- the next declaration starts
   with its own return type, binder, or keyword.

   `package` and `import` are the exception, and [header_decl] below says why.

   Inside a body the same declaration is a statement and does take `;`, unless
   it ends in a `}`; see [stat]. That is the one place the two levels differ in
   how a declaration is spelled. *)
package:
  | decls=list(top_decl) EOF {
      ({ Nodes.Package.decls; span = Span.of_loc $loc } : Nodes.Package.t)
    }

top_decl:
  | value=block_decl { value }
  | value=simple_decl { value }
  | value=header_decl ";" { value }

(* An identifier, carrying where it was written.

   Every name position in the grammar goes through one of these rather than
   reading the token directly, so no production can build a node with a name
   the reader cannot be pointed at. Both are `%inline`, so they expand back
   into their caller and the automaton is the same one the bare tokens built --
   the conflict census in docs/ambiguity.md is unchanged by their introduction.

   [import_member] is the one name position that does not use them: it is
   already a record whose own span is exactly the name. *)
%inline lname:
  | text=LIDENT { mk_name $loc text }

%inline uname:
  | text=UIDENT { mk_name $loc text }

%inline func_lambda(body_form):
  | ret_type=ret_type "(" params=separated_list(COMMA, param) ")" body=body_form {
      ({ Nodes.Func_lambda.params; ret_type; body; span = Span.of_loc $loc }
        : Nodes.Func_lambda.t)
    }

%inline meth_lambda(body_form):
  | ret_type=ret_type "(" THIS this_type=type_expr
    params=loption(preceded(",", separated_nonempty_list(",", param)))
    ")" is_mut=boption(MUT) body=body_form {
      ({
        Nodes.Meth_lambda.this_type;
        params;
        ret_type;
        is_mut;
        body;
        span = Span.of_loc $loc;
      } : Nodes.Meth_lambda.t)
    }

%inline concept:
  | "Type" {
      concept $loc Nodes.Concept.Type
    }
  | "Number" {
      concept $loc Nodes.Concept.Number
    }

%inline generic_arg:
  | type_expr=type_expr {
      generic_arg $loc (Nodes.Generic_arg.Type type_expr)
    }
  | number=INT {
      generic_arg $loc (Nodes.Generic_arg.Number number)
    }
  | name=lname {
      generic_arg $loc (Nodes.Generic_arg.NumberRef name)
    }
  | param=param {
      generic_arg $loc (Nodes.Generic_arg.Inferred param)
    }

%inline generics:
  | "<" generics=separated_nonempty_list(",", generic_arg) ">" {
      generics
    }

%inline named_type_expr:
  | name=name_type generics=loption(generics) {
      type_expr $loc (Nodes.Type_expr.Path { name; generics })
    }

%inline type_base:
  | type_=named_type_expr {
      type_
    }
  | "(" type_=type_expr ")" {
      type_expr $loc (Nodes.Type_expr.Parenthesized type_)
    }

%inline type_atom:
  | type_=type_base {
      type_
    }
  | "&" type_=type_base {
      type_expr $loc (Nodes.Type_expr.Guest type_)
    }

(* A suffix is parsed as its own bracket group and only then applied to the
   return type written to its left, so neither the suffix's `$loc` nor the
   return type's span covers the node it builds. The span runs from the return
   type's start to the suffix's end, which is what [Span.join] is for. *)
%inline verb_type_suffix:
  | "[" params=separated_list(",", param_type) "]" {
      let suffix_span = Span.of_loc $loc in
      fun (ret_type : Nodes.Ret_type.t) ->
        let span = Span.join ret_type.Nodes.Ret_type.span suffix_span in
        ({
          Nodes.Type_expr.span;
          node =
            Nodes.Type_expr.Verb
              { Nodes.Verb_type.span; node = Nodes.Verb_type.Func { params; ret_type } };
        } : Nodes.Type_expr.t)
    }
  | "[" THIS this_type=type_expr
    params=loption(preceded(",", separated_nonempty_list(",", param_type)))
    "]" is_mut=boption(MUT) {
      let suffix_span = Span.of_loc $loc in
      fun (ret_type : Nodes.Ret_type.t) ->
        let span = Span.join ret_type.Nodes.Ret_type.span suffix_span in
        ({
          Nodes.Type_expr.span;
          node =
            Nodes.Type_expr.Verb
              {
                Nodes.Verb_type.span;
                node =
                  Nodes.Verb_type.Meth { this_type; params; ret_type; is_mut };
              };
        } : Nodes.Type_expr.t)
    }

(* Verb-type brackets bind more tightly than an unparenthesized abort return:
   `Int ? Error[]` is `Int ? (Error[])`. To make the abort return feed the
   verb type instead, group it explicitly: `(Int ? Error)[]`. *)
(* The [Ret_type.Safe] cast introduces no syntax of its own -- it is the type
   to its left, read as a return type -- so it takes that type's span. *)
type_expr:
  | atom=type_atom suffixes=list(verb_type_suffix) {
      List.fold_left
        (fun (type_ : Nodes.Type_expr.t) suffix ->
          suffix
            {
              Nodes.Ret_type.node = Nodes.Ret_type.Safe type_;
              span = type_.Nodes.Type_expr.span;
            })
        atom suffixes
    }
  | open_=LPAREN ret_type=abort_ret_type close=RPAREN
    first=verb_type_suffix rest=list(verb_type_suffix) {
      ignore open_;
      ignore close;
      let parenthesized =
        ({
          Nodes.Ret_type.node = Nodes.Ret_type.Parenthesized ret_type;
          span = Span.join (Span.of_loc $loc(open_)) (Span.of_loc $loc(close));
        } : Nodes.Ret_type.t)
      in
      let type_ = first parenthesized in
      List.fold_left
        (fun (type_ : Nodes.Type_expr.t) suffix ->
          suffix
            {
              Nodes.Ret_type.node = Nodes.Ret_type.Safe type_;
              span = type_.Nodes.Type_expr.span;
            })
        type_ rest
    }

%inline generic_param:
  | name=uname concept_=UTYPE {
      ignore concept_;
      ({
        Nodes.Generic_param.name;
        type_ = concept $loc(concept_) Nodes.Concept.Type;
        span = Span.of_loc $loc;
      } : Nodes.Generic_param.t)
    }
  | name=lname concept_=NUMBER {
      ignore concept_;
      ({
        Nodes.Generic_param.name;
        type_ = concept $loc(concept_) Nodes.Concept.Number;
        span = Span.of_loc $loc;
      } : Nodes.Generic_param.t)
    }

%inline constructor_name:
  | type_=name_type member=ioption(preceded(".", lname)) {
      ({ Nodes.Constructor_name.type_; member; span = Span.of_loc $loc }
        : Nodes.Constructor_name.t)
    }

%inline field_arg:
  | name=lname value=ioption(preceded("=", expr)) {
      ({ Nodes.Field_arg.name; value; span = Span.of_loc $loc }
        : Nodes.Field_arg.t)
    }

(* A braced run of statements handed to a call and run by the callee. It is not
   an expression: it may be written only where a call takes arguments, which is
   what keeps a block from being stored, returned, or bound to a symbol. *)
%inline block_arg:
  | "{" stats=list(stat) "}" {
      call_arg $loc (Nodes.Call_arg.Block stats)
    }

(* A `{ }` body of `;`-terminated `key, value` entries. It stands in a value
   position behind no introducing token, which is also true of a block
   argument, so in argument position the two can meet. What tells them apart is
   the mark after the first expression: a `,` opens an entry's value, a `;`
   ends a statement. A literal is never empty, so a bare `{}` is a block. *)
%inline map_entry:
  | key=expr "," value=expr {
      (key, value)
    }

map_lit:
  | "{" entries=nonempty_list(terminated(map_entry, ";")) "}" {
      expr $loc (Nodes.Expr.MapLit entries)
    }

%inline call_arg:
  | value=expr { call_arg $loc (Nodes.Call_arg.Value value) }
  | block=block_arg { block }

%inline call_args:
  | args=separated_list(",", call_arg) { args }

(* The empty positional list is a production of its own rather than a
   [call_args] that happens to be empty, so that the non-empty list is written
   once and both spellings of a constructor call -- with a trailing argument
   and without -- read it through the same production. Written as one list
   either way, the parser has to pick between them while reducing the list, at
   the `)`; written like this it shifts the `)` and decides on the token that
   actually decides, the `{` or its absence. The state count is the same
   twelve; what changes is which fork they are, and this one is the fork
   docs/ambiguity.md already carries for a call's trailing argument against an
   enclosing brace. *)
%inline constructor_args:
  | "(" ")" {
      constructor_args $loc (Nodes.Constructor_args.Positional [])
    }
  | "(" args=separated_nonempty_list(",", call_arg) ")" {
      constructor_args $loc (Nodes.Constructor_args.Positional args)
    }
  | "{" args=list(terminated(field_arg, ";")) "}" {
      constructor_args $loc (Nodes.Constructor_args.Fields args)
    }

(* A named type after the binder either is the field's own type or introduces an
   inferred type parameter. Constructor fields and parameters spell that pair the
   same way, so both take it from here. *)
%inline field_type:
  | type_=type_expr {
      param_type $loc (Nodes.Param_type.Concrete type_)
    }
  | name=uname concept_=UTYPE {
      ignore concept_;
      param_type $loc
        (Nodes.Param_type.InferredType
           { name; concept = concept $loc(concept_) Nodes.Concept.Type })
    }

%inline constructor_field:
  | name=lname type_=field_type default=ioption(preceded("=", expr)) {
      ({ Nodes.Constructor_field.name; type_; default; span = Span.of_loc $loc }
        : Nodes.Constructor_field.t)
    }
  (* The field's type is not written: it is the constructor being called, read
     as a type. It stands for the *type* part of that name and not the whole of
     it -- `x Span.point(0)` declares a field of type `Span`, so the type node
     takes the span of `Span` rather than of `Span.point`, which is wider than
     anything it represents.

     The default is the call, so it runs from the constructor name through the
     arguments. The production's own span would start at the field binder,
     which is not part of the call. *)
  | name=lname constructor=constructor_name args=constructor_args {
      let type_span =
        constructor.Nodes.Constructor_name.type_.Nodes.Name_type.span
      in
      let type_ =
        ({
          Nodes.Type_expr.node =
            Nodes.Type_expr.Path
              { name = constructor.Nodes.Constructor_name.type_; generics = [] };
          span = type_span;
        } : Nodes.Type_expr.t)
      in
      let default =
        constructor_expr ($startpos(constructor), $endpos(args)) constructor args
      in
      ({
        Nodes.Constructor_field.name;
        type_ =
          { Nodes.Param_type.node = Nodes.Param_type.Concrete type_; span = type_span };
        default = Some default;
        span = Span.of_loc $loc;
      } : Nodes.Constructor_field.t)
    }

%inline constructor_params:
  | "(" params=separated_list(",", param) ")" {
      constructor_params $loc (Nodes.Constructor_params.Positional params)
    }
  | "{" fields=list(terminated(constructor_field, ";")) "}" {
      constructor_params $loc (Nodes.Constructor_params.Fields fields)
    }

%inline constructor_decl_name:
  | type_=named_type_expr member=ioption(preceded(".", lname)) {
      (type_, member)
    }

%inline enum_map_entry:
  | member=lname "=" value=expr {
      (member, value)
    }

(* An enum map's entries are a `{ }` body, so they no longer share a bracket
   with the verb-type suffixes of the property's own type. The type is an
   ordinary [type_expr] again and the entries follow it, which is what the
   earlier shift-every-group-then-classify shape existed to work around: with
   `[ ]` on both, whether a group was a suffix or the entry list depended on
   what came after its closing bracket. `{ }` answers that at the opening
   bracket, so the run of groups, the two rejected orders, and the classifier
   carrying a group's kind are all gone. *)
%inline enum_map_body:
  | "{" entries=list(terminated(enum_map_entry, ";")) "}" {
      entries
    }

(* A name taken from a package, in either casing class. *)
%inline import_member:
  | name=LIDENT {
      ({ Nodes.Import_member.name; is_type = false; span = Span.of_loc $loc }
        : Nodes.Import_member.t)
    }
  | name=UIDENT {
      ({ Nodes.Import_member.name; is_type = true; span = Span.of_loc $loc }
        : Nodes.Import_member.t)
    }

(* The four import forms. What the file writes at the use site is what the
   import wrote after `import`, so each form is its own production rather than
   one shape with optional parts.

   `import pkg$` takes everything past the separator and so ends on the `$`
   itself. What follows the `$` is settled by the terminator [header_decl]
   requires, not by reading on: see there. *)
import_decl:
  | IMPORT package=lname alias=ioption(preceded(AS, lname)) {
      import $loc (Nodes.Import.Package { package; alias })
    }
  | IMPORT package=lname "$" member=import_member
    alias=ioption(preceded(AS, import_member)) {
      import $loc
        (Nodes.Import.Member {
          package;
          member;
          alias = Option.map (import_alias member) alias;
        })
    }
  | IMPORT package=lname "$"
    "[" members=separated_nonempty_list(",", import_member) "]" {
      import $loc (Nodes.Import.Members { package; members })
    }
  | IMPORT package=lname "$" {
      import $loc (Nodes.Import.All { package })
    }

(* The two declarations that end in a bare name, and the only two that carry a
   terminator at package scope.

   Every other declaration ends in a body, a bracket, or an expression, so the
   declaration after it starts where its own shape says it stopped. These two
   stop at a name, and `import pkg$` stops before one: after the `$` a name is
   either the member being imported or the first token of the next
   declaration, and nothing in either shape tells the reader -- or the parser
   -- which. Carrying both readings until one fails to be a declaration is not
   enough, because both can succeed: `import core$ main Unit() { }` is a
   whole-package import followed by a lambda-valued declaration, and also a
   member import of `main` followed by a constructor declaration for `Unit`.
   That was an ambiguity the search found, not a fork that resolves.

   So the `;` is required here and the grammar carries the rule, which is
   where docs/ambiguity.md says a rule belongs when the grammar can hold it. A
   terminator after the `$` leaves the name nowhere to go but the next
   declaration, and the same `;` is what ends `package pkg` and the three
   import forms that do end in a name. *)
header_decl:
  | PACKAGE name=lname {
      decl $loc (Nodes.Decl.Package name)
    }
  | value=import_decl {
      decl $loc (Nodes.Decl.Import value)
    }

(* A verb declaration and the declaration wrapping it span the same tokens:
   there is nothing in a `Decl.Verb` but the verb. Both take `$loc`. *)
body_decl(body_form):
  | ret_type=ret_type name=lname "(" params=separated_list(",", param) ")" body=body_form {
      decl $loc
        (Nodes.Decl.Verb
           (verb_decl $loc
              (Nodes.Verb_decl.Func { name; params; ret_type; body })))
    }
  | ret_type=ret_type name=lname "(" THIS this_type=type_expr
    params=loption(preceded(",", separated_nonempty_list(",", param)))
    ")" is_mut=boption(MUT) body=body_form {
      decl $loc
        (Nodes.Decl.Verb
           (verb_decl $loc
              (Nodes.Verb_decl.Meth {
                name;
                this_type;
                params;
                ret_type;
                is_mut;
                body;
              })))
    }
  | type_=constructor_decl_name params=constructor_params body=body_form {
      let type_, member = type_ in
      decl $loc
        (Nodes.Decl.Verb
           (verb_decl $loc
              (Nodes.Verb_decl.Constructor {
                type_;
                member;
                params;
                body;
                is_implicit = false;
              })))
    }
  (* The parameter list is `( param )`, brackets included, so its node spans
     them: the sole parameter's own span would leave the parentheses out of the
     thing that is precisely a parenthesized list. *)
  | IMPLICIT type_=named_type_expr open_=LPAREN param=param close=RPAREN
    body=body_form {
      ignore open_;
      ignore close;
      decl $loc
        (Nodes.Decl.Verb
           (verb_decl $loc
              (Nodes.Verb_decl.Constructor {
                type_;
                member = None;
                params =
                  constructor_params
                    ($startpos(open_), $endpos(close))
                    (Nodes.Constructor_params.Positional [param]);
                body;
                is_implicit = true;
              })))
    }
  | ret_type=ret_type op=operator "(" params=separated_list(",", param) ")" body=body_form {
      decl $loc
        (Nodes.Decl.Verb
           (verb_decl $loc (Nodes.Verb_decl.Op { op; params; ret_type; body })))
    }
  | ret_type=ret_type "~" "(" params=separated_list(",", param) ")" body=body_form {
      decl $loc
        (Nodes.Decl.Verb
           (verb_decl $loc (Nodes.Verb_decl.Flip { params; ret_type; body })))
    }

(* Ends in a `{ }` block, which closes the construct on its own. *)
type_decl(value_form):
  | "type" name=uname params=loption(delimited("<", separated_nonempty_list(",", generic_param), ">"))
    "=" value=value_form {
      decl $loc (Nodes.Decl.Type { name; params; value })
    }
  | "alias" name=uname params=loption(delimited("<", separated_nonempty_list(",", generic_param), ">"))
    "=" value=value_form {
      decl $loc (Nodes.Decl.Alias { name; params; value })
    }

block_decl:
  | value=body_decl(block_body) { value }
  | value=type_decl(moulded_value) { value }

(* Ends in an expression, so it needs the terminator. *)
simple_decl:
  | value=body_decl(shorthand_body) { value }
  | value=type_decl(raw_value) { value }
  | value=type_decl(enum_moulded_value) { value }
  | name=lname type_=type_expr "=" value=expr {
      decl $loc (Nodes.Decl.Var { name; type_; value })
    }
  | name=lname constructor=constructor_name args=constructor_args {
      decl $loc
        (Nodes.Decl.VarShorthand { name; constructor; args; trailing = false })
    }
  (* The same instantiation with the call's last argument trailing, under the
     same restriction the call itself is under: what stays inside the `( )`
     may not be empty, or `name Foo() { ... }` would read both as this and as
     the lambda-variable shorthand two rules down. *)
  | name=lname constructor=constructor_name
    open_=LPAREN args=separated_nonempty_list(",", call_arg) RPAREN
    tail=trailing_arg {
      ignore open_;
      decl $loc
        (Nodes.Decl.VarShorthand {
          name;
          constructor;
          (* The arguments run from the `(` through the trailing argument. The
             production's own span would start at the binder and the
             constructor name, neither of which is an argument. *)
          args =
            constructor_args
              ($startpos(open_), $endpos(tail))
              (Nodes.Constructor_args.Positional (args @ tail));
          trailing = true;
        })
    }
  | name=lname func_lambda=func_lambda(body) {
      decl $loc
        (Nodes.Decl.Var {
          name;
          type_ = Nodes.func_type_of_lambda func_lambda;
          value = expr $loc(func_lambda) (Nodes.Expr.FuncLambda func_lambda);
        })
    }
  | name=lname meth_lambda=meth_lambda(body) {
      decl $loc
        (Nodes.Decl.Var {
          name;
          type_ = Nodes.meth_type_of_lambda meth_lambda;
          value = expr $loc(meth_lambda) (Nodes.Expr.MethLambda meth_lambda);
        })
    }
  | enum=named_type_expr "." property=lname type_=type_expr
    entries=enum_map_body {
      decl $loc (Nodes.Decl.EnumMap { enum; property; type_; entries })
    }
  | "(" THIS this_type=type_expr ")"
    "[" params=separated_list(",", param) "]" "=>" value=expr {
      decl $loc
        (Nodes.Decl.Verb
           (verb_decl $loc
              (Nodes.Verb_decl.Subscript { this_type; params; value })))
    }

%inline moulded_value:
  | value=moulded(braced_mould) {
      type_or_moulded $loc (Nodes.Type_or_moulded.Moulded value)
    }

%inline enum_moulded_value:
  | value=moulded(enum_mould) {
      type_or_moulded $loc (Nodes.Type_or_moulded.Moulded value)
    }

%inline raw_value:
  | value=type_expr {
      type_or_moulded $loc (Nodes.Type_or_moulded.Raw value)
    }

(* The moulds that close on a brace. A declaration ending in one is closed by
   it and takes no terminator, which is why they and the peer mould below are
   reached through different declaration rules. *)
%inline braced_mould:
  | STRUCT "{" fields=list(body_field) "}" {
      mould $loc (Nodes.Mould.Struct fields)
    }
  | VARIANT "{" fields=list(body_field) "}" {
      mould $loc (Nodes.Mould.Variant fields)
    }

(* The peer mould's contents are a flat list of names, so it takes `[ ]` and
   closes on a `]`. Which delimiter a mould uses is decided by its contents,
   and only a brace ends a statement -- so a declaration cast from this one is
   terminated like any other that does not end in a brace. *)
%inline enum_mould:
  | ENUM "[" members=separated_nonempty_list(",", lname) "]" {
      mould $loc (Nodes.Mould.Enum members)
    }

(* The value axis is written by the absence of a `#`, so it has no tokens of
   its own; it takes the mould's span, which is what a reader would be pointed
   at anyway. The reference axis takes the `#`. *)
%inline moulded(mould_form):
  | mould=mould_form {
      ({
        Nodes.Moulded.mould;
        axis = type_axis $loc(mould) Nodes.Type_axis.Value;
        span = Span.of_loc $loc;
      } : Nodes.Moulded.t)
    }
  | hash=HASH mould=mould_form {
      ignore hash;
      ({
        Nodes.Moulded.mould;
        axis = type_axis $loc(hash) Nodes.Type_axis.Reference;
        span = Span.of_loc $loc;
      } : Nodes.Moulded.t)
    }

%inline body_field:
  | name=lname type_=type_expr ";" {
      ({ Nodes.Body_field.name; type_; span = Span.of_loc $loc }
        : Nodes.Body_field.t)
    }

block_body:
  | "{" stats=list(stat) "}" {
      body $loc (Nodes.Body.Longhand stats)
    }

shorthand_body:
  | "=>" value=expr {
      body $loc (Nodes.Body.Shorthand value)
    }

body:
  | value=block_body { value }
  | value=shorthand_body { value }

ret_type:
  | value=type_expr {
      ret_type $loc (Nodes.Ret_type.Safe value)
    }
  | value=abort_ret_type {
      value
    }

abort_ret_type:
  | ok=type_expr "?" abort=type_expr {
      ret_type $loc (Nodes.Ret_type.Abort { ok; abort })
    }

%inline meth_part:
  | is_mut=mut_marker name=primary {
      (is_mut, name)
    }

%inline mut_marker:
  | ":" { false }
  | "!" { true }

(* At most one of a call's arguments may trail its closing `)`, where it still
   reads as the last argument. Only a `{ }` may take the position -- a block or
   a map literal -- because `{` is the one opening bracket that cannot also be
   read as a postfix on what precedes it: a trailing `[ ]` would collide with
   the subscript syntax. The two spellings are the same call, so the
   productions below take the tail as a parameter and build one node, recording
   only whether the argument was written outside the `)`, since that decides
   where the statement ends.

   A constructor call takes the same tail, but not through this rule: its
   callee is a [constructor_name] rather than an [app], so it is written out
   in [block_call] instead of being parameterized here. *)
%inline no_trailing_arg:
  | { ([] : Nodes.Call_arg.t list) }

%inline trailing_arg:
  | block=block_arg { [ block ] }
  | lit=map_lit { [ call_arg $loc (Nodes.Call_arg.Value lit) ] }

(* These build a function of the abort handler, because the handler is written
   to the call's right and reaches it through [attach_abort_handle]. The span
   captured here is the call's own -- through the `)` or the trailing argument,
   without the handler. The handler extends the enclosing [Expr], which is
   where [attach_abort_handle] re-spans. *)
computed_call(trailer):
  | receiver=func_callee "(" args=call_args ")" tail=trailer {
      let span = Span.of_loc $loc in
      fun abort_handle ->
        ({
          Nodes.Verb_call.span;
          node =
            Nodes.Verb_call.Func {
              callee = receiver;
              args = args @ tail;
              abort_handle;
              trailing = tail <> [];
            };
        } : Nodes.Verb_call.t)
    }
  | receiver=app part=meth_part "(" args=call_args ")" tail=trailer {
      let is_mut, callee = part in
      let span = Span.of_loc $loc in
      fun abort_handle ->
        ({
          Nodes.Verb_call.span;
          node =
            Nodes.Verb_call.Meth {
              callee;
              this = receiver;
              args = args @ tail;
              abort_handle;
              is_mut;
              trailing = tail <> [];
            };
        } : Nodes.Verb_call.t)
    }

verb_call:
  | call=computed_call(no_trailing_arg) { call }
  | name=constructor_name args=constructor_args {
      let span = Span.of_loc $loc in
      fun abort_handle ->
        ({
          Nodes.Verb_call.span;
          node =
            Nodes.Verb_call.Constructor
              { name; args; abort_handle; trailing = false };
        } : Nodes.Verb_call.t)
    }

(* A call closed by a trailing block. It is an expression rather than a postfix
   base, so a further postfix reaches what such a call produces only through
   parentheses. `spawn` takes a bare [verb_call] and so cannot reach one at all,
   which is where "a verb declaring a block parameter is never spawned" falls
   out of the grammar rather than being written as a rule. *)
block_call:
  | call=computed_call(trailing_arg) { call }
  (* A constructor call trails its last argument the same way, with two
     restrictions the casing rule puts on it and on nothing else.

     Only the positional form takes a tail: trailing elides the `)`, and the
     field form has none to elide -- it already closes on the `}` of its own
     field body.

     And what stays inside the `( )` may not be empty. `Foo() { ... }` is a
     nullary lambda literal whose return type is `Foo` (syntax.md §3.8), and
     in statement position a constructor declaration as well; both are written
     with an upper-case name in front of an empty bracket and a `{ }`, which
     is exactly the trailing form's own shape. A lower-case callee has no such
     reading, which is why `do() { ... }` is unambiguous and `Foo() { ... }`
     is not. A constructor call whose only argument is a block writes it
     inside the list. See docs/spec-divergences.md. *)
  | name=constructor_name
    open_=LPAREN args=separated_nonempty_list(",", call_arg) RPAREN
    tail=trailing_arg {
      ignore open_;
      let span = Span.of_loc $loc in
      (* As above: the call spans the whole production, its arguments only the
         `( )` list and the trailing argument -- not the callee. *)
      let args_span = ($startpos(open_), $endpos(tail)) in
      fun abort_handle ->
        ({
          Nodes.Verb_call.span;
          node =
            Nodes.Verb_call.Constructor {
              name;
              args =
                constructor_args args_span
                  (Nodes.Constructor_args.Positional (args @ tail));
              abort_handle;
              trailing = true;
            };
        } : Nodes.Verb_call.t)
    }

%inline operator:
  | op=comparison_decl_op { op }
  | op=additive_op        { op }
  | op=multiplicative_op  { op }

%inline comparison_decl_op:
  | "==" { operator $loc Nodes.Operator.Eq }
  | "<=" { operator $loc Nodes.Operator.LessEq }
  | ">=" { operator $loc Nodes.Operator.MoreEq }
  | "<"  { operator $loc Nodes.Operator.Less }
  | ">"  { operator $loc Nodes.Operator.More }

%inline comparison_op:
  | op=comparison_decl_op { op }
  | "~=" { operator $loc Nodes.Operator.NotEq }

%inline additive_op:
  | "+" { operator $loc Nodes.Operator.Add }
  | "-" { operator $loc Nodes.Operator.Sub }

%inline multiplicative_op:
  | "*" { operator $loc Nodes.Operator.Mul }
  | "/" { operator $loc Nodes.Operator.Div }

(* The loose forms carry the same [Operator.node] as the operators they mirror,
   because a loose operator "calls the same implementation as its unprefixed
   form and differs only in where it groups" (operators.md §3.1) and the
   grouping is the tree. What they do not share is [is_loose], because the two
   spellings are two different pieces of source and the CST records what was
   parsed; collapsing them is the SST's job (docs/desugaring.md §2.2).

   §3.1 is explicit that the loose forms add no token to the operator
   vocabulary of §5.1 -- so they declare nothing either, and the declaration
   productions, which read the unprefixed rules below, do not admit them. *)

%inline loose_comparison_op:
  | "'==" { loose_operator $loc Nodes.Operator.Eq }
  | "'~=" { loose_operator $loc Nodes.Operator.NotEq }
  | "'<=" { loose_operator $loc Nodes.Operator.LessEq }
  | "'>=" { loose_operator $loc Nodes.Operator.MoreEq }
  | "'<"  { loose_operator $loc Nodes.Operator.Less }
  | "'>"  { loose_operator $loc Nodes.Operator.More }

%inline loose_additive_op:
  | "'+" { loose_operator $loc Nodes.Operator.Add }
  | "'-" { loose_operator $loc Nodes.Operator.Sub }

%inline loose_multiplicative_op:
  | "'*" { loose_operator $loc Nodes.Operator.Mul }
  | "'/" { loose_operator $loc Nodes.Operator.Div }

%inline match_selector:
  | case=lname {
      [case]
    }
  | "[" cases=separated_nonempty_list(",", lname) "]" {
      cases
    }

%inline match_pattern:
  | cases=match_selector {
      ({ Nodes.Match_pattern.binder = None; cases; span = Span.of_loc $loc }
        : Nodes.Match_pattern.t)
    }
  | binder=lname cases=match_selector {
      ({
        Nodes.Match_pattern.binder = Some binder;
        cases;
        span = Span.of_loc $loc;
      } : Nodes.Match_pattern.t)
    }

(* An arm follows the same rule as a declaration body: `=> expr` needs the
   terminator, a `{ }` block closes itself. The spec terminates every arm; see
   docs/spec-divergences.md. *)
%inline match_arm:
  | patterns=separated_nonempty_list(",", match_pattern) body=block_body {
      ({ Nodes.Match_arm.patterns; body; span = Span.of_loc $loc }
        : Nodes.Match_arm.t)
    }
  | patterns=separated_nonempty_list(",", match_pattern) body=shorthand_body ";" {
      ({ Nodes.Match_arm.patterns; body; span = Span.of_loc $loc }
        : Nodes.Match_arm.t)
    }

(* The scrutinee list is parenthesized, and that is what keeps the arms' `{`
   attached to the `match` rather than to whatever the last scrutinee turned out
   to be. Written bare, the brace after the scrutinee has two owners: an `expr`
   may itself end in a brace -- a constructor's field body, a map literal, a
   call's trailing argument -- so `match A { } <= B { }` reads both as
   `(match A { }) <= (B { })` and as `match (A { } <= B) { }`. Both are complete
   derivations, which is the one thing docs/ambiguity.md does not allow; the `)`
   ends the scrutinee before the brace is read and neither reading survives it.

   The parentheses delimit the list; they do not build a value out of it. The
   scrutinees stay independent values matched jointly on their tags, exactly as
   before -- Zane has no `(a, b)` expression form for them to collapse into. *)
%inline match_expr:
  | MATCH "(" scrutinees=separated_nonempty_list(",", expr) ")"
    "{" arms=list(match_arm) "}" {
      expr $loc
        (Nodes.Expr.Match
           ({
             Nodes.Match_expr.scrutinees;
             arms;
             abort_handle = None;
             span = Span.of_loc $loc;
           } : Nodes.Match_expr.t))
    }

(* `spawn` takes the whole call, so it is an expression rather than a postfix
   base: `spawn false()()` spawns the outer call. Were it a `primary`, a
   trailing `(` could attach outside it as well as inside, giving the same
   tokens two readings. Parenthesize to call what a spawn produces. *)
%inline spawn_expr:
  | SPAWN call=verb_call {
      expr $loc (Nodes.Expr.Spawn (call None))
    }

(* Postfix bases are deliberately limited so that an uppercase `Type.member`
   has exactly one reading. Bare `Type.member` is a type-member value; when it
   is immediately followed by constructor arguments it is a named constructor
   or variant-case call, never a generic function call. *)
primary:
  | i=INT    { expr $loc (Nodes.Expr.IntLit i) }
  | f=FLOAT  { expr $loc (Nodes.Expr.FloatLit f) }
  | s=STRING { expr $loc (Nodes.Expr.StrLit s) }
  | TRUE     { expr $loc (Nodes.Expr.BoolLit true) }
  | FALSE    { expr $loc (Nodes.Expr.BoolLit false) }
  | "[" items=separated_list(",", expr) "]" {
      expr $loc (Nodes.Expr.CollectionLit items)
    }
  | THIS     {
      expr $loc
        (Nodes.Expr.NameExpr
           (name_expr $loc (Nodes.Name_expr.Ident (mk_name $loc "this"))))
    }
  | name_expr=name_expr { expr $loc (Nodes.Expr.NameExpr name_expr) }
  | "(" e=expr ")" { expr $loc (Nodes.Expr.Parenthized e) }
  | INIT "{" fields=list(terminated(field_arg, ";")) "}" {
      expr $loc (Nodes.Expr.Init fields)
    }
  | value=map_lit { value }
  | value=match_expr { value }

%inline type_member:
  | type_=name_type "." member=lname {
      expr $loc (Nodes.Expr.TypeMember { type_; member })
    }

(* `func_callee` excludes a bare type member. This is what keeps
   `Vector2.zeros()` out of the ordinary computed-call production while still
   allowing postfixes on the value produced by `Colors.red`.) *)
func_callee:
  | primary=primary { primary }
  | call=verb_call { expr $loc (Nodes.Expr.VerbCall (call None)) }
  | target=app "." field=lname {
      expr $loc (Nodes.Expr.DotAccess { target; field })
    }
  | target=app "[" args=separated_list(",", expr) "]" {
      expr $loc (Nodes.Expr.Subscript { target; args })
    }

app:
  | value=func_callee { value }
  | value=type_member { value }

expr:
  | app=app { app }
  (* A type passed as a value -- the explicit type argument of generics.md
     §5.3, as in `Array(Int, 10000)`.

     It sits here rather than in [primary] because a type is never a postfix
     base: there is no dot access on a type, no calling one (a name in front of
     an argument list is already a constructor call), and no subscripting one
     (a `[ ]` after a type name is a verb-type suffix). Written as a [primary]
     it would reach all three through [app], and `Colors.red`, `Int(3)` and
     `Span.point(0)` would each gain a second reading; written here it reaches
     none of them and every one of those stays at a single derivation.

     Only a bare name, for the reason [Nodes.Expr.TypeValue] records. *)
  | name=name_type { expr $loc (Nodes.Expr.TypeValue name) }
  | call=block_call { expr $loc (Nodes.Expr.VerbCall (call None)) }
  | value=spawn_expr { value }
  | func_lambda=func_lambda(body) {
      expr $loc (Nodes.Expr.FuncLambda func_lambda)
    }
  | meth_lambda=meth_lambda(body) {
      expr $loc (Nodes.Expr.MethLambda meth_lambda)
    }
  | left=expr op=comparison_op right=expr %prec EQEQ {
      expr $loc
        (Nodes.Expr.VerbCall
           (verb_call $loc
              (Nodes.Verb_call.Op { op; left; right; abort_handle = None })))
    }
  | left=expr op=additive_op right=expr %prec PLUS {
      expr $loc
        (Nodes.Expr.VerbCall
           (verb_call $loc
              (Nodes.Verb_call.Op { op; left; right; abort_handle = None })))
    }
  | left=expr op=multiplicative_op right=expr %prec STAR {
      expr $loc
        (Nodes.Expr.VerbCall
           (verb_call $loc
              (Nodes.Verb_call.Op { op; left; right; abort_handle = None })))
    }
  | left=expr op=loose_comparison_op right=expr %prec LOOSE_EQEQ {
      expr $loc
        (Nodes.Expr.VerbCall
           (verb_call $loc
              (Nodes.Verb_call.Op { op; left; right; abort_handle = None })))
    }
  | left=expr op=loose_additive_op right=expr %prec LOOSE_PLUS {
      expr $loc
        (Nodes.Expr.VerbCall
           (verb_call $loc
              (Nodes.Verb_call.Op { op; left; right; abort_handle = None })))
    }
  | left=expr op=loose_multiplicative_op right=expr %prec LOOSE_STAR {
      expr $loc
        (Nodes.Expr.VerbCall
           (verb_call $loc
              (Nodes.Verb_call.Op { op; left; right; abort_handle = None })))
    }
  (* The method target is the receiver and the name after the `:` or `!`, which
     together run from the receiver's start to the name's end. *)
  | receiver=app part=meth_part "|" value=expr %prec PIPE {
      let is_mut, callee = part in
      let target =
        expr
          ($startpos(receiver), $endpos(part))
          (Nodes.Expr.MethodTarget { callee; this = receiver; is_mut })
      in
      expr $loc (Nodes.Expr.Pipe { callee = target; value; abort_handle = None })
    }
  | callee=expr "|" value=expr %prec PIPE {
      expr $loc (Nodes.Expr.Pipe { callee; value; abort_handle = None })
    }
  | "~" value=expr %prec TILDE {
      expr $loc
        (Nodes.Expr.VerbCall
           (verb_call $loc
              (Nodes.Verb_call.Flip { value; abort_handle = None })))
    }
  | "&" value=ref_target %prec AMPERSAND {
      expr $loc (Nodes.Expr.Ref value)
    }
  | value=expr abort_handle=abort_handle %prec QSTNQSTN {
      attach_abort_handle abort_handle (Span.of_loc $loc) value
    }

(* What a reference may be taken of: a postfix chain, optionally under further
   prefixes. A bare lambda is excluded, so the leading `&` in `&Int () { }`
   belongs to the return type and the whole reads as a lambda returning `&Int`.
   Parenthesize the lambda to take a reference to it. *)
ref_target:
  | value=app { value }
  | "&" value=ref_target %prec AMPERSAND {
      expr $loc (Nodes.Expr.Ref value)
    }
  | "~" value=ref_target %prec TILDE {
      expr $loc
        (Nodes.Expr.VerbCall
           (verb_call $loc
              (Nodes.Verb_call.Flip { value; abort_handle = None })))
    }

abort_handle:
  | "?" binder=ioption(lname) body=body %prec THICK_ARROW {
      abort_handle_node $loc (Nodes.Abort_handle.Longhand { binder; body })
    }
  | "??" value=expr %prec THICK_ARROW {
      abort_handle_node $loc (Nodes.Abort_handle.Shorthand value)
    }

(* A `;` terminates a statement, unless the statement already ends in a `}` --
   then that brace closes it and a `;` would mark nothing. Every form below
   therefore takes the terminator as optional and hands it to
   [check_terminator], which rejects whichever of the two spellings the
   statement's own shape did not call for.

   Note what is *not* here: a bare `{ }` is not a statement. Scoping a run of
   work is a call taking a block argument, so the only braces that open
   anything at this level belong to a declaration. *)
stat:
  | target=app "=" value=expr terminated=boption(";") {
      expr_statement ~terminated ~ends_at:$endpos ~loc:$loc
        (fun value -> Nodes.Stat.Assign { target; value }) value
    }
  (* Ends in its own `{ }` body, so there was no terminator to get wrong. *)
  | decl=block_decl {
      braced_statement ~ends_at:$endpos ~loc:$loc
        ~continued:(decl_continues_past_trailing decl)
        (Nodes.Stat.Decl decl)
    }
  (* The grammar requires this one's `;` (see [header_decl]), so there was no
     terminator to get wrong here either. A statement is where the ambiguity
     reaches too -- a body holds `import pkg$` and the declaration after it on
     the same terms package scope does -- so the requirement has to hold at
     both levels to close it at either. *)
  | decl=header_decl ";" {
      terminated_statement ~loc:$loc (Nodes.Stat.Decl decl)
    }
  | decl=simple_decl terminated=boption(";") {
      statement
        ~ends_in_brace:(decl_ends_in_brace decl)
        ~terminated ~ends_at:$endpos ~loc:$loc
        ~continued:(decl_continues_past_trailing decl)
        (Nodes.Stat.Decl decl)
    }
  | call=verb_call abort_handle=ioption(abort_handle) terminated=boption(";") {
      let call = call abort_handle in
      statement
        ~ends_in_brace:(verb_call_ends_in_brace call)
        ~terminated ~ends_at:$endpos ~loc:$loc
        ~continued:(verb_call_continues_past_trailing call)
        (Nodes.Stat.VerbCall call)
    }
  (* Closed by its own trailing argument, so it takes no terminator and admits
     no abort handler -- nothing may continue the call past that brace. *)
  | call=block_call {
      let call = call None in
      braced_statement ~ends_at:$endpos ~loc:$loc
        ~continued:(verb_call_continues_past_trailing call)
        (Nodes.Stat.VerbCall call)
    }
  | SPAWN call=verb_call abort_handle=ioption(abort_handle) terminated=boption(";") {
      let call = call abort_handle in
      statement
        ~ends_in_brace:(verb_call_ends_in_brace call)
        ~terminated ~ends_at:$endpos ~loc:$loc
        ~continued:(verb_call_continues_past_trailing call)
        (Nodes.Stat.Spawn call)
    }
  | ABORT value=expr terminated=boption(";") {
      expr_statement ~terminated ~ends_at:$endpos ~loc:$loc
        (fun value -> Nodes.Stat.Abort value) value
    }
  | RETURN value=expr terminated=boption(";") {
      expr_statement ~terminated ~ends_at:$endpos ~loc:$loc
        (fun value -> Nodes.Stat.Ret value) value
    }
  | RESOLVE value=expr terminated=boption(";") {
      expr_statement ~terminated ~ends_at:$endpos ~loc:$loc
        (fun value -> Nodes.Stat.Resolve value) value
    }

%inline param_type:
  | type_=type_expr {
      param_type $loc (Nodes.Param_type.Concrete type_)
    }
  | type_=concept {
      param_type $loc (Nodes.Param_type.Concept type_)
    }

%inline param:
  | name=lname type_=field_type {
      ({ Nodes.Param.name; type_; span = Span.of_loc $loc } : Nodes.Param.t)
    }
  | name=uname concept_=UTYPE {
      ignore concept_;
      ({
        Nodes.Param.name;
        type_ =
          param_type $loc(concept_)
            (Nodes.Param_type.Concept
               (concept $loc(concept_) Nodes.Concept.Type));
        span = Span.of_loc $loc;
      } : Nodes.Param.t)
    }
  | name=lname concept_=NUMBER {
      ignore concept_;
      ({
        Nodes.Param.name;
        type_ =
          param_type $loc(concept_)
            (Nodes.Param_type.Concept
               (concept $loc(concept_) Nodes.Concept.Number));
        span = Span.of_loc $loc;
      } : Nodes.Param.t)
    }

%inline name_expr:
  | name=lname { name_expr $loc (Nodes.Name_expr.Ident name) }
  | pkg=lname "$" name=lname {
      name_expr $loc (Nodes.Name_expr.Qualified { package = pkg; ident = name })
    }
  | "@" pkg=lname "$" name=lname {
      name_expr $loc (Nodes.Name_expr.Intrinsic { package = pkg; ident = name })
    }

%inline name_type:
  | name=uname { name_type $loc (Nodes.Name_type.Ident name) }
  | pkg=lname "$" name=uname {
      name_type $loc (Nodes.Name_type.Qualified { package = pkg; ident = name })
    }
  | "@" pkg=lname "$" name=uname {
      name_type $loc (Nodes.Name_type.Intrinsic { package = pkg; ident = name })
    }
