%{
let attach_abort_handle expr abort_handle =
  let attach = function
    (* A trailing argument ends its statement, so nothing may continue the call
       past that `}` -- a handler included. The same call written with the
       argument inside the parentheses takes one. *)
    | Nodes.Verb_call.Func { trailing = true; _ }
    | Nodes.Verb_call.Meth { trailing = true; _ } ->
        raise
          (Parse_error.Rejected
             "a trailing argument ends the statement, so an abort handler \
              cannot follow it; write the argument inside the argument list")
    | Nodes.Verb_call.Func { callee; args; abort_handle = None; trailing } ->
        Nodes.Verb_call.Func {
          callee;
          args;
          abort_handle = Some abort_handle;
          trailing;
        }
    | Nodes.Verb_call.Meth { callee; this; args; abort_handle = None; is_mut; trailing } ->
        Nodes.Verb_call.Meth {
          callee;
          this;
          args;
          abort_handle = Some abort_handle;
          is_mut;
          trailing;
        }
    | Nodes.Verb_call.Constructor { name; args; abort_handle = None } ->
        Nodes.Verb_call.Constructor {
          name;
          args;
          abort_handle = Some abort_handle;
        }
    | Nodes.Verb_call.Op { op; left; right; abort_handle = None } ->
        Nodes.Verb_call.Op {
          op;
          left;
          right;
          abort_handle = Some abort_handle;
        }
    | Nodes.Verb_call.Flip { value; abort_handle = None } ->
        Nodes.Verb_call.Flip { value; abort_handle = Some abort_handle }
    | _ ->
        raise
          (Parse_error.Rejected "an operation can only have one abort handler")
  in
  let rec loop = function
    | Nodes.Expr.VerbCall call -> Nodes.Expr.VerbCall (attach call)
    | Nodes.Expr.Spawn call -> Nodes.Expr.Spawn (attach call)
    | Nodes.Expr.Match ({ abort_handle = None; _ } as match_) ->
        Nodes.Expr.Match { match_ with abort_handle = Some abort_handle }
    | Nodes.Expr.Pipe ({ abort_handle = None; _ } as pipe) ->
        Nodes.Expr.Pipe { pipe with abort_handle = Some abort_handle }
    | Nodes.Expr.Parenthized value -> Nodes.Expr.Parenthized (loop value)
    | _ ->
        raise
          (Parse_error.Rejected
             "an abort handler must follow an abortable operation")
  in
  loop expr

let constructor_expr name args =
  Nodes.Expr.VerbCall
    (Nodes.Verb_call.Constructor { name; args; abort_handle = None })

(* Does this statement's last token close a brace?

   A statement ends with `;`, unless it ends with a `}` -- then that brace ends
   it and a `;` after it would mark nothing. Which of the two a statement takes
   is therefore a property of its final token, which is a property of the
   shape at the tail of its tree: every form below either closes with a brace
   itself or hands the question to whatever it ends with.

   The grammar accepts a terminator either way and the check below rejects the
   spelling that does not match, rather than the language being split into
   brace-ending and non-brace-ending halves. A grammatical split would have to
   reach through every binary operator -- `a + match e { ... }` ends in a brace
   because its right operand does -- which means two copies of the expression
   grammar and two of every operator production. One function over the tree
   says the same thing once. *)
let rec expr_ends_in_brace (expr : Nodes.Expr.t) =
  match expr with
  | Nodes.Expr.Init _ | Nodes.Expr.MapLit _ -> true
  | Nodes.Expr.Match { abort_handle = Some handle; _ } ->
      abort_handle_ends_in_brace handle
  | Nodes.Expr.Match _ -> true
  | Nodes.Expr.VerbCall call | Nodes.Expr.Spawn call ->
      verb_call_ends_in_brace call
  | Nodes.Expr.Pipe { abort_handle = Some handle; _ } ->
      abort_handle_ends_in_brace handle
  | Nodes.Expr.Pipe { value; _ } -> expr_ends_in_brace value
  | Nodes.Expr.Logic { right; _ } -> expr_ends_in_brace right
  | Nodes.Expr.FuncLambda { body; _ } -> body_ends_in_brace body
  | Nodes.Expr.MethLambda { body; _ } -> body_ends_in_brace body
  | Nodes.Expr.Ref value -> expr_ends_in_brace value
  (* Only ever a [Pipe]'s callee, which is never the tail of the statement. *)
  | Nodes.Expr.MethodTarget _ -> false
  (* Closed by `)`, `]`, or the name itself. *)
  | Nodes.Expr.IntLit _ | Nodes.Expr.FloatLit _ | Nodes.Expr.StrLit _
  | Nodes.Expr.BoolLit _ | Nodes.Expr.CollectionLit _ | Nodes.Expr.NameExpr _
  | Nodes.Expr.TypeMember _ | Nodes.Expr.DotAccess _ | Nodes.Expr.Subscript _
  | Nodes.Expr.Parenthized _ ->
      false

and verb_call_ends_in_brace (call : Nodes.Verb_call.t) =
  match call with
  | Nodes.Verb_call.Func { abort_handle = Some handle; _ }
  | Nodes.Verb_call.Meth { abort_handle = Some handle; _ }
  | Nodes.Verb_call.Constructor { abort_handle = Some handle; _ }
  | Nodes.Verb_call.Op { abort_handle = Some handle; _ }
  | Nodes.Verb_call.Flip { abort_handle = Some handle; _ } ->
      abort_handle_ends_in_brace handle
  (* A trailing argument's `}` is the call's last token; without one the `)` is. *)
  | Nodes.Verb_call.Func { trailing; _ } | Nodes.Verb_call.Meth { trailing; _ } ->
      trailing
  | Nodes.Verb_call.Constructor { args = Nodes.Constructor_args.Fields _; _ } ->
      true
  | Nodes.Verb_call.Constructor _ -> false
  | Nodes.Verb_call.Op { right; _ } -> expr_ends_in_brace right
  | Nodes.Verb_call.Flip { value; _ } -> expr_ends_in_brace value

and abort_handle_ends_in_brace (handle : Nodes.Abort_handle.t) =
  match handle with
  | Nodes.Abort_handle.Shorthand value -> expr_ends_in_brace value
  | Nodes.Abort_handle.Longhand { body; _ } -> body_ends_in_brace body

and body_ends_in_brace (body : Nodes.Body.t) =
  match body with
  | Nodes.Body.Longhand _ -> true
  | Nodes.Body.Shorthand value -> expr_ends_in_brace value

(* A mould's delimiter is decided by its contents: named typed members take
   `{ }`, a flat list of names takes `[ ]`. Only the first closes a statement,
   so the shape has to be read rather than assumed from the value being
   moulded at all. *)
let moulded_ends_in_brace (moulded : Nodes.Moulded.t) =
  match moulded.Nodes.Moulded.mould with
  | Nodes.Mould.Struct _ | Nodes.Mould.Variant _ -> true
  | Nodes.Mould.Enum _ -> false

let decl_ends_in_brace (decl : Nodes.Decl.t) =
  match decl with
  | Nodes.Decl.Package _ | Nodes.Decl.Import _ -> false
  | Nodes.Decl.Var { value; _ } -> expr_ends_in_brace value
  | Nodes.Decl.VarShorthand { args = Nodes.Constructor_args.Fields _; _ } -> true
  | Nodes.Decl.VarShorthand _ -> false
  | Nodes.Decl.Type { value = Nodes.Type_or_moulded.Moulded moulded; _ }
  | Nodes.Decl.Alias { value = Nodes.Type_or_moulded.Moulded moulded; _ } ->
      moulded_ends_in_brace moulded
  (* Cast from a bare type expression, which closes on a name, `]`, `>` or `)`. *)
  | Nodes.Decl.Type _ | Nodes.Decl.Alias _ -> false
  (* Its entries are a `{ }` body. *)
  | Nodes.Decl.EnumMap _ -> true
  | Nodes.Decl.Verb (Nodes.Verb_decl.Subscript { value; _ }) ->
      expr_ends_in_brace value
  | Nodes.Decl.Verb (Nodes.Verb_decl.Func { body; _ })
  | Nodes.Decl.Verb (Nodes.Verb_decl.Meth { body; _ })
  | Nodes.Decl.Verb (Nodes.Verb_decl.Op { body; _ })
  | Nodes.Decl.Verb (Nodes.Verb_decl.Constructor { body; _ })
  | Nodes.Decl.Verb (Nodes.Verb_decl.Flip { body; _ }) ->
      body_ends_in_brace body

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
let rec ends_in_trailing_call (expr : Nodes.Expr.t) =
  match expr with
  | Nodes.Expr.VerbCall (Nodes.Verb_call.Func { abort_handle = None; trailing; _ })
  | Nodes.Expr.VerbCall (Nodes.Verb_call.Meth { abort_handle = None; trailing; _ }) ->
      trailing
  | Nodes.Expr.VerbCall (Nodes.Verb_call.Op { right; abort_handle = None; _ }) ->
      ends_in_trailing_call right
  | Nodes.Expr.VerbCall (Nodes.Verb_call.Flip { value; abort_handle = None }) ->
      ends_in_trailing_call value
  | Nodes.Expr.Logic { right; _ } -> ends_in_trailing_call right
  | Nodes.Expr.Pipe { value; abort_handle = None; _ } ->
      ends_in_trailing_call value
  | Nodes.Expr.Ref value -> ends_in_trailing_call value
  | _ -> false

(* Is a trailing argument's `}` written anywhere an operand continues past it?
   Only the left of a binary form can do that: the right is the tail, and
   whether the tail may end that way is the enclosing statement's question.
   Parentheses close the call before the operator sees it, which is how such a
   value is continued, so [Parenthized] is not searched. *)
let rec continues_past_trailing (expr : Nodes.Expr.t) =
  match expr with
  | Nodes.Expr.VerbCall (Nodes.Verb_call.Op { left; right; _ }) ->
      ends_in_trailing_call left || continues_past_trailing left
      || continues_past_trailing right
  | Nodes.Expr.Logic { left; right; _ } ->
      ends_in_trailing_call left || continues_past_trailing left
      || continues_past_trailing right
  | Nodes.Expr.Pipe { callee; value; _ } ->
      ends_in_trailing_call callee || continues_past_trailing callee
      || continues_past_trailing value
  | Nodes.Expr.VerbCall (Nodes.Verb_call.Flip { value; _ }) ->
      continues_past_trailing value
  | Nodes.Expr.Ref value -> continues_past_trailing value
  | _ -> false

(* A declaration's own tail, for the same question. *)
let decl_continues_past_trailing (decl : Nodes.Decl.t) =
  match decl with
  | Nodes.Decl.Var { value; _ } -> continues_past_trailing value
  | Nodes.Decl.Verb (Nodes.Verb_decl.Subscript { value; _ }) ->
      continues_past_trailing value
  | Nodes.Decl.Verb (Nodes.Verb_decl.Func { body = Nodes.Body.Shorthand value; _ })
  | Nodes.Decl.Verb (Nodes.Verb_decl.Meth { body = Nodes.Body.Shorthand value; _ })
  | Nodes.Decl.Verb (Nodes.Verb_decl.Op { body = Nodes.Body.Shorthand value; _ })
  | Nodes.Decl.Verb (Nodes.Verb_decl.Constructor { body = Nodes.Body.Shorthand value; _ })
  | Nodes.Decl.Verb (Nodes.Verb_decl.Flip { body = Nodes.Body.Shorthand value; _ }) ->
      continues_past_trailing value
  | _ -> false

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
let statement ~ends_in_brace ~terminated ~ends_at ~continued stat =
  let defect =
    if continued then
      Some (Nodes.Statement_defect.Continued_trailing_argument, ends_at)
    else if ends_in_brace <> terminated then None
    else if terminated then
      Some (Nodes.Statement_defect.Stray_semicolon, ends_at)
    else Some (Nodes.Statement_defect.Missing_semicolon, ends_at)
  in
  ({ Nodes.Statement.stat; defect } : Nodes.Statement.t)

(* A statement whose tail is an expression. *)
let expr_statement ~terminated ~ends_at build value =
  statement
    ~ends_in_brace:(expr_ends_in_brace value)
    ~terminated ~ends_at
    ~continued:(continues_past_trailing value)
    (build value)

(* Closed by its own brace, so there was never a terminator to get wrong. *)
let braced_statement stat =
  ({ Nodes.Statement.stat; defect = None } : Nodes.Statement.t)
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
%token AND         "and"
%token OR          "or"
%token SPAWN       "spawn"
%token TRUE        "true"
%token FALSE       "false"
%token THIS        "this"
%token MUT         "mut"
%token ABORT       "abort"
%token RETURN      "return"
%token RESOLVE     "resolve"
%token EOF          "<eof>"

(* Keep the existing grouping decisions. New syntax is inserted around them
   rather than respelling existing programs to match the prose spec. *)
%right THICK_ARROW
%left OR                                        /* short-circuit or */
%left AND                                       /* short-circuit and */
%left EQEQ NOTEQ LESSEQ MOREEQ LESS MORE       /* comparisons */
%left PLUS MINUS
%left STAR SLASH
%left PIPE                                      /* pipe */
%nonassoc QSTNMARK QSTNQSTN                    /* abort handling */
%nonassoc TILDE AMPERSAND                       /* prefix ~ and & */
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

   Inside a body the same declaration is a statement and does take `;`, unless
   it ends in a `}`; see [stat]. That is the one place the two levels differ in
   how a declaration is spelled. *)
package:
  | decls=list(top_decl) EOF { { Nodes.Package.decls = decls } }

top_decl:
  | value=block_decl { value }
  | value=simple_decl { value }

%inline func_lambda(body_form):
  | ret_type=ret_type "(" params=separated_list(COMMA, param) ")" body=body_form {
      { Nodes.Func_lambda.params; ret_type; body }
    }

%inline meth_lambda(body_form):
  | ret_type=ret_type "(" THIS this_type=type_expr
    params=loption(preceded(",", separated_nonempty_list(",", param)))
    ")" is_mut=boption(MUT) body=body_form {
      { Nodes.Meth_lambda.this_type; params; ret_type; is_mut; body }
    }

%inline concept:
  | "Type" {
      Nodes.Concept.Type
    }
  | "Number" {
      Nodes.Concept.Number
    }

%inline generic_arg:
  | type_expr=type_expr {
      Nodes.Generic_arg.Type type_expr
    }
  | number=INT {
      Nodes.Generic_arg.Number number
    }
  | name=LIDENT {
      Nodes.Generic_arg.NumberRef name
    }
  | param=param {
      Nodes.Generic_arg.Inferred param
    }

%inline generics:
  | "<" generics=separated_nonempty_list(",", generic_arg) ">" {
      generics
    }

%inline named_type_expr:
  | name=name_type generics=loption(generics) {
      Nodes.Type_expr.Path { name; generics }
    }

%inline type_base:
  | type_=named_type_expr {
      type_
    }
  | "(" type_=type_expr ")" {
      Nodes.Type_expr.Parenthesized type_
    }

%inline type_atom:
  | type_=type_base {
      type_
    }
  | "&" type_=type_base {
      Nodes.Type_expr.Guest type_
    }

%inline verb_type_suffix:
  | "[" params=separated_list(",", param_type) "]" {
      fun ret_type ->
        Nodes.Type_expr.Verb (Nodes.Verb_type.Func { params; ret_type })
    }
  | "[" THIS this_type=type_expr
    params=loption(preceded(",", separated_nonempty_list(",", param_type)))
    "]" is_mut=boption(MUT) {
      fun ret_type ->
        Nodes.Type_expr.Verb (Nodes.Verb_type.Meth {
          this_type;
          params;
          ret_type;
          is_mut;
        })
    }

(* Verb-type brackets bind more tightly than an unparenthesized abort return:
   `Int ? Error[]` is `Int ? (Error[])`. To make the abort return feed the
   verb type instead, group it explicitly: `(Int ? Error)[]`. *)
type_expr:
  | atom=type_atom suffixes=list(verb_type_suffix) {
      List.fold_left
        (fun type_ suffix -> suffix (Nodes.Ret_type.Safe type_))
        atom suffixes
    }
  | "(" ret_type=abort_ret_type ")"
    first=verb_type_suffix rest=list(verb_type_suffix) {
      let type_ = first (Nodes.Ret_type.Parenthesized ret_type) in
      List.fold_left
        (fun type_ suffix -> suffix (Nodes.Ret_type.Safe type_))
        type_ rest
    }

%inline generic_param:
  | name=UIDENT "Type" {
      ({ Nodes.Generic_param.name; type_ = Nodes.Concept.Type } : Nodes.Generic_param.t)
    }
  | name=LIDENT "Number" {
      ({ Nodes.Generic_param.name; type_ = Nodes.Concept.Number } : Nodes.Generic_param.t)
    }

%inline constructor_name:
  | type_=name_type member=ioption(preceded(".", LIDENT)) {
      ({ Nodes.Constructor_name.type_; member } : Nodes.Constructor_name.t)
    }

%inline field_arg:
  | name=LIDENT value=ioption(preceded("=", expr)) {
      ({ Nodes.Field_arg.name; value } : Nodes.Field_arg.t)
    }

(* A braced run of statements handed to a call and run by the callee. It is not
   an expression: it may be written only where a call takes arguments, which is
   what keeps a block from being stored, returned, or bound to a symbol. *)
%inline block_arg:
  | "{" stats=list(stat) "}" {
      Nodes.Call_arg.Block stats
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
      Nodes.Expr.MapLit entries
    }

%inline call_arg:
  | value=expr { Nodes.Call_arg.Value value }
  | block=block_arg { block }

%inline call_args:
  | args=separated_list(",", call_arg) { args }

%inline constructor_args:
  | "(" args=call_args ")" {
      Nodes.Constructor_args.Positional args
    }
  | "{" args=list(terminated(field_arg, ";")) "}" {
      Nodes.Constructor_args.Fields args
    }

(* A named type after the binder either is the field's own type or introduces an
   inferred type parameter. Constructor fields and parameters spell that pair the
   same way, so both take it from here. *)
%inline field_type:
  | type_=type_expr {
      Nodes.Param_type.Concrete type_
    }
  | name=UIDENT "Type" {
      Nodes.Param_type.InferredType { name; concept = Nodes.Concept.Type }
    }

%inline constructor_field:
  | name=LIDENT type_=field_type default=ioption(preceded("=", expr)) {
      ({ Nodes.Constructor_field.name; type_; default } : Nodes.Constructor_field.t)
    }
  | name=LIDENT constructor=constructor_name args=constructor_args {
      let type_ = Nodes.Type_expr.Path { name = constructor.type_; generics = [] } in
      let default = constructor_expr constructor args in
      ({
        Nodes.Constructor_field.name;
        type_ = Nodes.Param_type.Concrete type_;
        default = Some default;
      } : Nodes.Constructor_field.t)
    }

%inline constructor_params:
  | "(" params=separated_list(",", param) ")" {
      Nodes.Constructor_params.Positional params
    }
  | "{" fields=list(terminated(constructor_field, ";")) "}" {
      Nodes.Constructor_params.Fields fields
    }

%inline constructor_decl_name:
  | type_=named_type_expr member=ioption(preceded(".", LIDENT)) {
      (type_, member)
    }

%inline enum_map_entry:
  | member=LIDENT "=" value=expr {
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
      ({ Nodes.Import_member.name; is_type = false } : Nodes.Import_member.t)
    }
  | name=UIDENT {
      ({ Nodes.Import_member.name; is_type = true } : Nodes.Import_member.t)
    }

(* The four import forms. What the file writes at the use site is what the
   import wrote after `import`, so each form is its own production rather than
   one shape with optional parts.

   `import pkg$` takes everything past the separator and so ends on the `$`
   itself. Since a package-scope declaration carries no terminator, the name
   that follows one belongs to the next declaration, and the parser settles
   which by carrying both readings until one of them fails to be a
   declaration. *)
import_decl:
  | IMPORT package=LIDENT alias=ioption(preceded(AS, LIDENT)) {
      Nodes.Import.Package { package; alias }
    }
  | IMPORT package=LIDENT "$" member=import_member
    alias=ioption(preceded(AS, import_member)) {
      Nodes.Import.Member {
        package;
        member;
        alias = Option.map (import_alias member) alias;
      }
    }
  | IMPORT package=LIDENT "$"
    "[" members=separated_nonempty_list(",", import_member) "]" {
      Nodes.Import.Members { package; members }
    }
  | IMPORT package=LIDENT "$" {
      Nodes.Import.All { package }
    }

body_decl(body_form):
  | ret_type=ret_type name=LIDENT "(" params=separated_list(",", param) ")" body=body_form {
      Nodes.Decl.Verb (Nodes.Verb_decl.Func { name; params; ret_type; body })
    }
  | ret_type=ret_type name=LIDENT "(" THIS this_type=type_expr
    params=loption(preceded(",", separated_nonempty_list(",", param)))
    ")" is_mut=boption(MUT) body=body_form {
      Nodes.Decl.Verb (Nodes.Verb_decl.Meth {
        name;
        this_type;
        params;
        ret_type;
        is_mut;
        body;
      })
    }
  | type_=constructor_decl_name params=constructor_params body=body_form {
      let type_, member = type_ in
      Nodes.Decl.Verb (Nodes.Verb_decl.Constructor {
        type_;
        member;
        params;
        body;
        is_implicit = false;
      })
    }
  | IMPLICIT type_=named_type_expr "(" param=param ")" body=body_form {
      Nodes.Decl.Verb (Nodes.Verb_decl.Constructor {
        type_;
        member = None;
        params = Nodes.Constructor_params.Positional [param];
        body;
        is_implicit = true;
      })
    }
  | ret_type=ret_type op=operator "(" params=separated_list(",", param) ")" body=body_form {
      Nodes.Decl.Verb (Nodes.Verb_decl.Op { op; params; ret_type; body })
    }
  | ret_type=ret_type "~" "(" params=separated_list(",", param) ")" body=body_form {
      Nodes.Decl.Verb (Nodes.Verb_decl.Flip { params; ret_type; body })
    }

(* Ends in a `{ }` block, which closes the construct on its own. *)
type_decl(value_form):
  | "type" name=UIDENT params=loption(delimited("<", separated_nonempty_list(",", generic_param), ">"))
    "=" value=value_form {
      Nodes.Decl.Type { name; params; value }
    }
  | "alias" name=UIDENT params=loption(delimited("<", separated_nonempty_list(",", generic_param), ">"))
    "=" value=value_form {
      Nodes.Decl.Alias { name; params; value }
    }

block_decl:
  | value=body_decl(block_body) { value }
  | value=type_decl(moulded_value) { value }

(* Ends in an expression, so it needs the terminator. *)
simple_decl:
  | value=body_decl(shorthand_body) { value }
  | value=type_decl(raw_value) { value }
  | value=type_decl(enum_moulded_value) { value }
  | PACKAGE name=LIDENT {
      Nodes.Decl.Package name
    }
  | value=import_decl {
      Nodes.Decl.Import value
    }
  | name=LIDENT type_=type_expr "=" value=expr {
      Nodes.Decl.Var { name; type_; value }
    }
  | name=LIDENT constructor=constructor_name args=constructor_args {
      Nodes.Decl.VarShorthand { name; constructor; args }
    }
  | name=LIDENT func_lambda=func_lambda(body) {
      Nodes.Decl.Var {
        name;
        type_ = Nodes.func_type_of_lambda func_lambda;
        value = Nodes.Expr.FuncLambda func_lambda;
      }
    }
  | name=LIDENT meth_lambda=meth_lambda(body) {
      Nodes.Decl.Var {
        name;
        type_ = Nodes.meth_type_of_lambda meth_lambda;
        value = Nodes.Expr.MethLambda meth_lambda;
      }
    }
  | enum=named_type_expr "." property=LIDENT type_=type_expr
    entries=enum_map_body {
      Nodes.Decl.EnumMap { enum; property; type_; entries }
    }
  | "(" THIS this_type=type_expr ")"
    "[" params=separated_list(",", param) "]" "=>" value=expr {
      Nodes.Decl.Verb (Nodes.Verb_decl.Subscript { this_type; params; value })
    }

%inline moulded_value:
  | value=moulded(braced_mould) {
      Nodes.Type_or_moulded.Moulded value
    }

%inline enum_moulded_value:
  | value=moulded(enum_mould) {
      Nodes.Type_or_moulded.Moulded value
    }

%inline raw_value:
  | value=type_expr {
      Nodes.Type_or_moulded.Raw value
    }

(* The moulds that close on a brace. A declaration ending in one is closed by
   it and takes no terminator, which is why they and the peer mould below are
   reached through different declaration rules. *)
%inline braced_mould:
  | STRUCT "{" fields=list(body_field) "}" {
      Nodes.Mould.Struct fields
    }
  | VARIANT "{" fields=list(body_field) "}" {
      Nodes.Mould.Variant fields
    }

(* The peer mould's contents are a flat list of names, so it takes `[ ]` and
   closes on a `]`. Which delimiter a mould uses is decided by its contents,
   and only a brace ends a statement -- so a declaration cast from this one is
   terminated like any other that does not end in a brace. *)
%inline enum_mould:
  | ENUM "[" members=separated_nonempty_list(",", LIDENT) "]" {
      Nodes.Mould.Enum members
    }

%inline moulded(mould_form):
  | mould=mould_form {
      { Nodes.Moulded.mould; axis = Nodes.Type_axis.Value }
    }
  | "#" mould=mould_form {
      { Nodes.Moulded.mould; axis = Nodes.Type_axis.Reference }
    }

%inline body_field:
  | name=LIDENT type_=type_expr ";" {
      ({ Nodes.Body_field.name; type_ } : Nodes.Body_field.t)
    }

block_body:
  | "{" stats=list(stat) "}" {
      Nodes.Body.Longhand stats
    }

shorthand_body:
  | "=>" value=expr {
      Nodes.Body.Shorthand value
    }

body:
  | value=block_body { value }
  | value=shorthand_body { value }

ret_type:
  | value=type_expr {
      Nodes.Ret_type.Safe value
    }
  | value=abort_ret_type {
      value
    }

abort_ret_type:
  | ok=type_expr "?" abort=type_expr {
      Nodes.Ret_type.Abort { ok; abort }
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

   A constructor call is left out of this rule, because `Foo() { ... }` already
   spells a constructor declaration with a block body; a constructor takes its
   blocks in the argument list. See docs/spec-divergences.md. *)
%inline no_trailing_arg:
  | { ([] : Nodes.Call_arg.t list) }

%inline trailing_arg:
  | block=block_arg { [ block ] }
  | lit=map_lit { [ Nodes.Call_arg.Value lit ] }

computed_call(trailer):
  | receiver=func_callee "(" args=call_args ")" tail=trailer {
      fun abort_handle -> Nodes.Verb_call.Func {
        callee = receiver;
        args = args @ tail;
        abort_handle;
        trailing = tail <> [];
      }
    }
  | receiver=app part=meth_part "(" args=call_args ")" tail=trailer {
      let is_mut, callee = part in
      fun abort_handle -> Nodes.Verb_call.Meth {
        callee;
        this = receiver;
        args = args @ tail;
        abort_handle;
        is_mut;
        trailing = tail <> [];
      }
    }

verb_call:
  | call=computed_call(no_trailing_arg) { call }
  | name=constructor_name args=constructor_args {
      fun abort_handle -> Nodes.Verb_call.Constructor { name; args; abort_handle }
    }

(* A call closed by a trailing block. It is an expression rather than a postfix
   base, so a further postfix reaches what such a call produces only through
   parentheses. `spawn` takes a bare [verb_call] and so cannot reach one at all,
   which is where "a verb declaring a block parameter is never spawned" falls
   out of the grammar rather than being written as a rule. *)
block_call:
  | call=computed_call(trailing_arg) { call }

%inline operator:
  | op=comparison_decl_op { op }
  | op=additive_op        { op }
  | op=multiplicative_op  { op }

%inline comparison_decl_op:
  | "==" { Nodes.Operator.Eq }
  | "<=" { Nodes.Operator.LessEq }
  | ">=" { Nodes.Operator.MoreEq }
  | "<"  { Nodes.Operator.Less }
  | ">"  { Nodes.Operator.More }

%inline comparison_op:
  | op=comparison_decl_op { op }
  | "~=" { Nodes.Operator.NotEq }

%inline additive_op:
  | "+" { Nodes.Operator.Add }
  | "-" { Nodes.Operator.Sub }

%inline multiplicative_op:
  | "*" { Nodes.Operator.Mul }
  | "/" { Nodes.Operator.Div }

%inline match_selector:
  | case=LIDENT {
      [case]
    }
  | "[" cases=separated_nonempty_list(",", LIDENT) "]" {
      cases
    }

%inline match_pattern:
  | cases=match_selector {
      ({ Nodes.Match_pattern.binder = None; cases } : Nodes.Match_pattern.t)
    }
  | binder=LIDENT cases=match_selector {
      ({ Nodes.Match_pattern.binder = Some binder; cases } : Nodes.Match_pattern.t)
    }

(* An arm follows the same rule as a declaration body: `=> expr` needs the
   terminator, a `{ }` block closes itself. The spec terminates every arm; see
   docs/spec-divergences.md. *)
%inline match_arm:
  | patterns=separated_nonempty_list(",", match_pattern) body=block_body {
      ({ Nodes.Match_arm.patterns; body } : Nodes.Match_arm.t)
    }
  | patterns=separated_nonempty_list(",", match_pattern) body=shorthand_body ";" {
      ({ Nodes.Match_arm.patterns; body } : Nodes.Match_arm.t)
    }

%inline match_expr:
  | MATCH scrutinees=separated_nonempty_list(",", expr)
    "{" arms=list(match_arm) "}" {
      Nodes.Expr.Match { scrutinees; arms; abort_handle = None }
    }

(* `spawn` takes the whole call, so it is an expression rather than a postfix
   base: `spawn false()()` spawns the outer call. Were it a `primary`, a
   trailing `(` could attach outside it as well as inside, giving the same
   tokens two readings. Parenthesize to call what a spawn produces. *)
%inline spawn_expr:
  | SPAWN call=verb_call {
      Nodes.Expr.Spawn (call None)
    }

(* Postfix bases are deliberately limited so that an uppercase `Type.member`
   has exactly one reading. Bare `Type.member` is a type-member value; when it
   is immediately followed by constructor arguments it is a named constructor
   or variant-case call, never a generic function call. *)
primary:
  | i=INT    { Nodes.Expr.IntLit i }
  | f=FLOAT  { Nodes.Expr.FloatLit f }
  | s=STRING { Nodes.Expr.StrLit s }
  | TRUE     { Nodes.Expr.BoolLit true }
  | FALSE    { Nodes.Expr.BoolLit false }
  | "[" items=separated_list(",", expr) "]" { Nodes.Expr.CollectionLit items }
  | THIS     { Nodes.Expr.NameExpr (Nodes.Name_expr.Ident "this") }
  | name_expr=name_expr { Nodes.Expr.NameExpr name_expr }
  | "(" e=expr ")" { Nodes.Expr.Parenthized e }
  | INIT "{" fields=list(terminated(field_arg, ";")) "}" {
      Nodes.Expr.Init fields
    }
  | value=map_lit { value }
  | value=match_expr { value }

%inline type_member:
  | type_=name_type "." member=LIDENT {
      Nodes.Expr.TypeMember { type_; member }
    }

(* `func_callee` excludes a bare type member. This is what keeps
   `Vector2.zeros()` out of the ordinary computed-call production while still
   allowing postfixes on the value produced by `Colors.red`.) *)
func_callee:
  | primary=primary { primary }
  | call=verb_call { Nodes.Expr.VerbCall (call None) }
  | target=app "." field=LIDENT {
      Nodes.Expr.DotAccess { target; field }
    }
  | target=app "[" args=separated_list(",", expr) "]" {
      Nodes.Expr.Subscript { target; args }
    }

app:
  | value=func_callee { value }
  | value=type_member { value }

expr:
  | app=app { app }
  | call=block_call { Nodes.Expr.VerbCall (call None) }
  | value=spawn_expr { value }
  | func_lambda=func_lambda(body) { Nodes.Expr.FuncLambda func_lambda }
  | meth_lambda=meth_lambda(body) { Nodes.Expr.MethLambda meth_lambda }
  | left=expr op=comparison_op right=expr %prec EQEQ {
      Nodes.Expr.VerbCall (Nodes.Verb_call.Op {
        op;
        left;
        right;
        abort_handle = None;
      })
    }
  | left=expr op=additive_op right=expr %prec PLUS {
      Nodes.Expr.VerbCall (Nodes.Verb_call.Op {
        op;
        left;
        right;
        abort_handle = None;
      })
    }
  | left=expr op=multiplicative_op right=expr %prec STAR {
      Nodes.Expr.VerbCall (Nodes.Verb_call.Op {
        op;
        left;
        right;
        abort_handle = None;
      })
    }
  | receiver=app part=meth_part "|" value=expr %prec PIPE {
      let is_mut, callee = part in
      let callee = Nodes.Expr.MethodTarget { callee; this = receiver; is_mut } in
      Nodes.Expr.Pipe { callee; value; abort_handle = None }
    }
  | callee=expr "|" value=expr %prec PIPE {
      Nodes.Expr.Pipe { callee; value; abort_handle = None }
    }
  | left=expr "and" right=expr %prec AND {
      Nodes.Expr.Logic { op = Nodes.Logic_op.And; left; right }
    }
  | left=expr "or" right=expr %prec OR {
      Nodes.Expr.Logic { op = Nodes.Logic_op.Or; left; right }
    }
  | "~" value=expr %prec TILDE {
      Nodes.Expr.VerbCall (Nodes.Verb_call.Flip {
        value;
        abort_handle = None;
      })
    }
  | "&" value=ref_target %prec AMPERSAND {
      Nodes.Expr.Ref value
    }
  | value=expr abort_handle=abort_handle %prec QSTNQSTN {
      attach_abort_handle value abort_handle
    }

(* What a reference may be taken of: a postfix chain, optionally under further
   prefixes. A bare lambda is excluded, so the leading `&` in `&Int () { }`
   belongs to the return type and the whole reads as a lambda returning `&Int`.
   Parenthesize the lambda to take a reference to it. *)
ref_target:
  | value=app { value }
  | "&" value=ref_target %prec AMPERSAND {
      Nodes.Expr.Ref value
    }
  | "~" value=ref_target %prec TILDE {
      Nodes.Expr.VerbCall (Nodes.Verb_call.Flip {
        value;
        abort_handle = None;
      })
    }

abort_handle:
  | "?" binder=ioption(LIDENT) body=body %prec THICK_ARROW {
      Nodes.Abort_handle.Longhand { binder; body }
    }
  | "??" value=expr %prec THICK_ARROW {
      Nodes.Abort_handle.Shorthand value
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
      expr_statement ~terminated ~ends_at:$endpos
        (fun value -> Nodes.Stat.Assign { target; value }) value
    }
  (* Ends in its own `{ }` body, so there was no terminator to get wrong. *)
  | decl=block_decl {
      braced_statement (Nodes.Stat.Decl decl)
    }
  | decl=simple_decl terminated=boption(";") {
      statement
        ~ends_in_brace:(decl_ends_in_brace decl)
        ~terminated ~ends_at:$endpos
        ~continued:(decl_continues_past_trailing decl)
        (Nodes.Stat.Decl decl)
    }
  | call=verb_call abort_handle=ioption(abort_handle) terminated=boption(";") {
      let call = call abort_handle in
      statement
        ~ends_in_brace:(verb_call_ends_in_brace call)
        ~terminated ~ends_at:$endpos
        ~continued:(continues_past_trailing (Nodes.Expr.VerbCall call))
        (Nodes.Stat.VerbCall call)
    }
  (* Closed by its own trailing argument, so it takes no terminator and admits
     no abort handler -- nothing may continue the call past that brace. *)
  | call=block_call {
      braced_statement (Nodes.Stat.VerbCall (call None))
    }
  | SPAWN call=verb_call abort_handle=ioption(abort_handle) terminated=boption(";") {
      let call = call abort_handle in
      statement
        ~ends_in_brace:(verb_call_ends_in_brace call)
        ~terminated ~ends_at:$endpos
        ~continued:(continues_past_trailing (Nodes.Expr.VerbCall call))
        (Nodes.Stat.Spawn call)
    }
  | ABORT value=expr terminated=boption(";") {
      expr_statement ~terminated ~ends_at:$endpos
        (fun value -> Nodes.Stat.Abort value) value
    }
  | RETURN value=expr terminated=boption(";") {
      expr_statement ~terminated ~ends_at:$endpos
        (fun value -> Nodes.Stat.Ret value) value
    }
  | RESOLVE value=expr terminated=boption(";") {
      expr_statement ~terminated ~ends_at:$endpos
        (fun value -> Nodes.Stat.Resolve value) value
    }

%inline param_type:
  | type_=type_expr {
      Nodes.Param_type.Concrete type_
    }
  | type_=concept {
      Nodes.Param_type.Concept type_
    }

%inline param:
  | name=LIDENT type_=field_type {
      ({ Nodes.Param.name; type_ } : Nodes.Param.t)
    }
  | name=UIDENT "Type" {
      ({ Nodes.Param.name; type_ = Nodes.Param_type.Concept Nodes.Concept.Type } : Nodes.Param.t)
    }
  | name=LIDENT "Number" {
      ({ Nodes.Param.name; type_ = Nodes.Param_type.Concept Nodes.Concept.Number } : Nodes.Param.t)
    }

%inline name_expr:
  | name=LIDENT { Nodes.Name_expr.Ident name }
  | pkg=LIDENT "$" name=LIDENT { Nodes.Name_expr.Qualified { package = pkg; ident = name } }
  | "@" pkg=LIDENT "$" name=LIDENT { Nodes.Name_expr.Intrinsic { package = pkg; ident = name } }

%inline name_type:
  | name=UIDENT { Nodes.Name_type.Ident name }
  | pkg=LIDENT "$" name=UIDENT { Nodes.Name_type.Qualified { package = pkg; ident = name } }
  | "@" pkg=LIDENT "$" name=UIDENT { Nodes.Name_type.Intrinsic { package = pkg; ident = name } }
