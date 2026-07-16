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
%token DOLLAR      "$"
%token HASH        "#"
%token AND         "&"
%token AT          "@"
%token EXCL        "!"
%token QSTNMARK    "?"
%token QSTNQSTN    "??"
%token TILDE       "~"
%token THICK_ARROW "=>"
%token EQEQ        "=="
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
%token TUPLE       "tuple"
%token ENUM        "enum"
%token IF          "if"
%token ELIF        "elif"
%token ELSE        "else"
%token TRUE        "true"
%token LOOP        "loop"
%token FROM        "from"
%token TO          "to"
%token FALSE       "false"
%token THIS        "this"
%token MUT         "mut"
%token ABORT       "abort"
%token RETURN      "return"
%token RESOLVE     "resolve"
%token EOF          "<eof>"

%nonassoc EQEQ LESSEQ MOREEQ LESS MORE   /* comparisons */
%left PLUS MINUS
%left STAR SLASH
%left LPAREN                             /* function application */
%nonassoc TILDE AND                      /* prefix ~ and & */
%left DOT                                /* field access */

%start <Nodes.Package.t> package

(*************************)
(*     grammar rules     *)
(*************************)
%%

package:
  | decls=list(decl) EOF { { Nodes.Package.decls = decls } }

%inline func_lambda:
  | ret_type=ret_type "(" params=separated_list(COMMA, param) ")" body=body {
      { Nodes.Func_lambda.params; ret_type; body }
    }

%inline meth_lambda:
  | ret_type=ret_type "(" THIS this_type=type_expr
    params=loption(preceded(",", separated_nonempty_list(",", param)))
    ")" is_mut=boption(MUT) body=body {
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
  | param=param {
      Nodes.Generic_arg.Inferred param
    }

%inline generics:
  | "<" generics=separated_nonempty_list(",", generic_arg) ">" {
      generics
    }

type_expr:
  | name=name_type generics=loption(generics) {
      Nodes.Type_expr.Path { name; generics }
    }
  | verb_type=verb_type {
      Nodes.Type_expr.Verb verb_type
    }

%inline generic_param:
  | name=UIDENT "Type" {
      ({ Nodes.Generic_param.name; type_ = Nodes.Concept.Type } : Nodes.Generic_param.t)
    }
  | name=LIDENT "Number" {
      ({ Nodes.Generic_param.name; type_ = Nodes.Concept.Number } : Nodes.Generic_param.t)
    }

decl:
  | name=LIDENT type_=type_expr "=" value=expr {
      Nodes.Decl.Var { name; type_; value }
    }
  | name=LIDENT constructor=name_type "(" args=separated_list(COMMA, expr) ")" {
      Nodes.Decl.VarShorthand { name; constructor; args }
    }
  | name=LIDENT func_lambda=func_lambda {
      Nodes.Decl.Var {
        name;
        type_ = Nodes.func_type_of_lambda func_lambda;
        value = Nodes.Expr.FuncLambda func_lambda
      }
    }
  | name=LIDENT meth_lambda=meth_lambda {
      Nodes.Decl.Var {
        name;
        type_ = Nodes.meth_type_of_lambda meth_lambda;
        value = Nodes.Expr.MethLambda meth_lambda
      }
    }
  | ret_type=ret_type name=LIDENT
    "(" params=separated_list(COMMA, param) ")" body=body {
      Nodes.Decl.Verb (Nodes.Verb_decl.Func {
        name;
        params;
        ret_type;
        body;
      })
    }
  | ret_type=ret_type name=LIDENT
    "(" THIS this_type=type_expr
    params=loption(preceded(",", separated_nonempty_list(",", param)))
    ")" is_mut=boption(MUT) body=body {
      Nodes.Decl.Verb (Nodes.Verb_decl.Meth {
        name;
        this_type;
        params;
        ret_type;
        is_mut;
        body;
      })
    }
  | type_=name_type
    "(" params=separated_list(COMMA, param) ")" body=body {
      Nodes.Decl.Verb (Nodes.Verb_decl.Constructor {
        type_;
        params;
        body;
      })
    }
  | ret_type=ret_type op=operator "(" params=separated_list(COMMA, param) ")" body=body {
      Nodes.Decl.Verb (Nodes.Verb_decl.Op {
        op;
        params;
        ret_type;
        body;
      })
    }
  | ret_type=ret_type "~" "(" params=separated_list(COMMA, param) ")" body=body {
      Nodes.Decl.Verb (Nodes.Verb_decl.Flip {
        params;
        ret_type;
        body;
      })
    }
  | "type" name=UIDENT params=loption(delimited("<", separated_nonempty_list(",", generic_param), ">")) "=" value=type_or_moulded {
      Nodes.Decl.Type {
        name;
        params;
        value;
      }
    }
  | "alias" name=UIDENT params=loption(delimited("<", separated_nonempty_list(",", generic_param), ">")) "=" value=type_expr {
      Nodes.Decl.Alias {
        name;
        params;
        value;
      }
    }

(* value-identifier counterpart to name_type — both segments lowercase
   since Name_expr lives in the value namespace (LIDENT), unlike
   Name_type's qualified form which ends in a UIDENT type name. *)
%inline name_expr:
  | name=LIDENT { Nodes.Name_expr.Ident name }
  | pkg=LIDENT "$" name=LIDENT { Nodes.Name_expr.Qualified { package = pkg; ident = name } }
  | "@" pkg=LIDENT "$" name=LIDENT { Nodes.Name_expr.Intrinsic { package = pkg; ident = name } }

%inline comparison_op:
  | "==" { Nodes.Operator.Eq }
  | "<=" { Nodes.Operator.LessEq }
  | ">=" { Nodes.Operator.MoreEq }
  | "<"  { Nodes.Operator.Less }
  | ">"  { Nodes.Operator.More }

%inline additive_op:
  | "+" { Nodes.Operator.Add }
  | "-" { Nodes.Operator.Sub }

%inline multiplicative_op:
  | "*" { Nodes.Operator.Mul }
  | "/" { Nodes.Operator.Div }

(* used by decl's operator-overload form, e.g. `Int +(other Int) { ... }` —
   a single bare operator token, no left/right operands involved there *)
%inline operator:
  | op=comparison_op     { op }
  | op=additive_op       { op }
  | op=multiplicative_op { op }

expr:
  | i=INT    { Nodes.Expr.IntLit i }
  | f=FLOAT  { Nodes.Expr.FloatLit f }
  | s=STRING { Nodes.Expr.StrLit s }
  | TRUE     { Nodes.Expr.BoolLit true }
  | FALSE    { Nodes.Expr.BoolLit false }
  | name_expr=name_expr { Nodes.Expr.NameExpr name_expr }
  | "(" e=expr ")" { Nodes.Expr.Parenthized e }
  | func_lambda=func_lambda { Nodes.Expr.FuncLambda func_lambda }
  | meth_lambda=meth_lambda { Nodes.Expr.MethLambda meth_lambda }
  | verb_call=verb_call { Nodes.Expr.VerbCall verb_call }
  | target=expr "." field=LIDENT {
      Nodes.Expr.DotAccess { target; field }
    }
  | left=expr op=comparison_op right=expr abort_handle=ioption(abort_handle) %prec EQEQ {
      Nodes.Expr.VerbCall (Nodes.Verb_call.Op { op; left; right; abort_handle })
    }
  | left=expr op=additive_op right=expr abort_handle=ioption(abort_handle) %prec PLUS {
      Nodes.Expr.VerbCall (Nodes.Verb_call.Op { op; left; right; abort_handle })
    }
  | left=expr op=multiplicative_op right=expr abort_handle=ioption(abort_handle) %prec STAR {
      Nodes.Expr.VerbCall (Nodes.Verb_call.Op { op; left; right; abort_handle })
    }
  | "~" value=expr abort_handle=ioption(abort_handle) %prec TILDE {
      Nodes.Expr.VerbCall (Nodes.Verb_call.Flip { value; abort_handle })
    }
  | "&" value=expr %prec AND {
      Nodes.Expr.Ref value
    }

%inline body_field:
  | name=LIDENT type_=type_expr ";" {
      { Nodes.Body_field.name; type_ }
    }

%inline mould:
  | STRUCT "{" fields=list(body_field) "}" {
      Nodes.Mould.Struct fields
    }
  | VARIANT "{" fields=list(body_field) "}" {
      Nodes.Mould.Variant fields
    }
  | ENUM "[" members=separated_nonempty_list(",", LIDENT) "]" {
      Nodes.Mould.Enum members
    }
  | TUPLE "[" members=separated_nonempty_list(",", type_expr) "]" {
      Nodes.Mould.Tuple members
    }

%inline moulded:
  | mould=mould {
      { Nodes.Moulded.mould; axis = Nodes.Type_axis.Value }
    }
  | "#" mould=mould {
      { Nodes.Moulded.mould; axis = Nodes.Type_axis.Reference }
    }

%inline type_or_moulded:
  | type_expr=type_expr {
      Nodes.Type_or_moulded.Raw type_expr
    }
  | moulded=moulded {
      Nodes.Type_or_moulded.Moulded moulded
    }

%inline ret_type:
  | ret_type=type_expr {
      Nodes.Ret_type.Safe ret_type
    }
  | ok=type_expr "?" abort=type_expr {
      Nodes.Ret_type.Abort { ok; abort }
    }

body:
  | "{" statements=list(stat) "}" {
      Nodes.Body.Longhand statements
    }
  | "=>" value=expr {
      Nodes.Body.Shorthand value
    }

%inline abort_handle:
  | "?" binder=ioption(LIDENT) body=body {
      Nodes.Abort_handle.Longhand { binder; body }
    }
  | "??" value=expr {
      Nodes.Abort_handle.Shorthand value
    }

verb_call:
  | callee=expr "(" args=separated_list(COMMA, expr) ")" abort_handle=ioption(abort_handle) %prec LPAREN {
      Nodes.Verb_call.Func { callee; args; abort_handle }
    }
  | this=expr "!" callee=expr "(" args=separated_list(COMMA, expr) ")" abort_handle=ioption(abort_handle) %prec LPAREN {
      Nodes.Verb_call.Meth { callee; this; args; abort_handle; is_mut = true }
    }
  | this=expr ":" callee=expr "(" args=separated_list(COMMA, expr) ")" abort_handle=ioption(abort_handle) %prec LPAREN {
      Nodes.Verb_call.Meth { callee; this; args; abort_handle; is_mut = false }
    }
  | name_type=name_type "(" args=separated_list(COMMA, expr) ")" abort_handle=ioption(abort_handle) %prec LPAREN {
      Nodes.Verb_call.Constructor { name_type; args; abort_handle }
    }

%inline if_:
  | IF cond=expr "{" block=list(stat) "}" {
      { Nodes.Cond_block.cond; block }
    }

%inline elif_:
  | ELIF cond=expr "{" block=list(stat) "}" {
      { Nodes.Cond_block.cond; block }
    }

%inline else_:
  | ELSE "{" statements=list(stat) "}" {
      statements
    }

%inline loop:
  | LOOP binder=LIDENT start=ioption(preceded(FROM, expr)) TO end_=expr "{" statements=list(stat) "}" {
      ({ Nodes.Loop.start; end_; binder; body = statements } : Nodes.Loop.t)
    }

stat:
  | decl=decl { Nodes.Stat.Decl decl }
  | verb_call=verb_call {
      Nodes.Stat.VerbCall verb_call
    }
  | ABORT value=expr {
      Nodes.Stat.Abort value
    }
  | RETURN value=expr {
      Nodes.Stat.Ret value
    }
  | RESOLVE value=expr {
      Nodes.Stat.Resolve value
    }
  | if_=if_ elifs_=list(elif_) else_=ioption(else_) {
      Nodes.Stat.CondSeq Nodes.Cond_seq.{ if_; elifs_; else_ }
    }
  | loop=loop {
      Nodes.Stat.Loop loop
    }

%inline param_type:
  | type_=type_expr {
      Nodes.Param_type.Concrete type_
    }
  | type_=concept {
      Nodes.Param_type.Concept type_
    }

%inline param:
  | name=LIDENT type_=type_expr {
      ({ Nodes.Param.name; type_ = Nodes.Param_type.Concrete type_ } : Nodes.Param.t)
    }
  | name=UIDENT "Type" {
      ({ Nodes.Param.name; type_ = Nodes.Param_type.Concept Nodes.Concept.Type } : Nodes.Param.t)
    }
  | name=LIDENT "Number" {
      ({ Nodes.Param.name; type_ = Nodes.Param_type.Concept Nodes.Concept.Number } : Nodes.Param.t)
    }

%inline name_type:
  | name=UIDENT { Nodes.Name_type.Ident name }
  | pkg=LIDENT "$" name=UIDENT { Nodes.Name_type.Qualified { package = pkg; ident = name } }
  | "@" pkg=LIDENT "$" name=UIDENT { Nodes.Name_type.Intrinsic { package = pkg; ident = name } }

%inline verb_type:
  | ret=ret_type "[" params=separated_list(",", param_type) "]" {
      Nodes.Verb_type.Func { params; ret_type = ret }
    }
  | ret=ret_type "[" THIS this_type=type_expr
    params=loption(preceded(",", separated_nonempty_list(",", param_type)))
    "]" is_mut=boption(MUT) {
      Nodes.Verb_type.Meth { this_type; params; ret_type = ret; is_mut }
    }

