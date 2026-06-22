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
%token CLASS       "class"
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
%token ERROR       "<error>"
%token EOF          "<eof>"

%nonassoc EQEQ LESSEQ MOREEQ LESS MORE   /* comparisons */
%left PLUS MINUS
%left STAR SLASH
%left LPAREN                             /* function application */
%nonassoc IF
%nonassoc ELSE
%nonassoc TILDE                          /* prefix ~ */
%left DOT                                /* field access */

%start <Nodes.package> package

(*************************)
(*     grammar rules     *)
(*************************)
%%

package:
  | decls=list(decl) EOF { { Nodes.decls=decls } }

%inline func_lambda:
  | ret_type=ret_type "(" params=separated_list(COMMA, param) ")" body=body {
      { Nodes.params; ret_type; body }
    }

%inline meth_lambda:
  | ret_type=ret_type "(" THIS this_type=type_expr
    params=loption(preceded(",", separated_nonempty_list(",", param)))
    ")" is_mut=boption(MUT) body=body {
      { Nodes.this_type; params; ret_type; is_mut; body }
    }

%inline generic_param_type:
  | "Type" {
      Nodes.TypeParam
    }
  | "Number" {
      Nodes.NumberParam
    }

%inline generic_param:
  | name=UIDENT type_=generic_param_type {
     ({ name; type_ }: Nodes.generic_param)
    }

decl:
  | name=LIDENT type_=type_expr "=" value=expr {
      Nodes.VarDecl { name; type_; value }
    }
  | name=LIDENT type_=name_type "(" args=separated_list(COMMA, expr) ")" {
      Nodes.VarDeclShorthand { name; type_; args }
    }
  | name=LIDENT func_lambda=func_lambda {
      Nodes.VarDecl {
        name;
        type_=Nodes.func_type_of_lambda func_lambda;
        value=Nodes.FuncLambda func_lambda
      }
    }
  | name=LIDENT meth_lambda=meth_lambda {
      Nodes.VarDecl {
        name;
        type_=Nodes.meth_type_of_lambda meth_lambda;
        value=Nodes.MethLambda meth_lambda
      }
    }
  | ret_type=ret_type name=LIDENT
    "(" params=separated_list(COMMA, param) ")" body=body {
      Nodes.FuncDecl {
        name;
        params;
        ret_type;
        body;
      }
    }
  | ret_type=ret_type name=LIDENT
    "(" THIS this_type=type_expr
    params=loption(preceded(",", separated_nonempty_list(",", param)))
    ")" is_mut=boption(MUT) body=body {
      Nodes.MethDecl {
        name;
        this_type;
        params;
        ret_type;
        is_mut;
        body;
      }
    }
  | type_=name_type
    "(" params=separated_list(COMMA, param) ")" body=body {
      Nodes.ConstructorDecl {
        type_;
        params;
        body;
      }
    }
  | ret_type=ret_type op=operator "(" params=separated_list(COMMA, param) ")" body=body {
      Nodes.OpDecl {
        op;
        params;
        ret_type;
        body;
      }
    }
  | ret_type=ret_type "~" "(" params=separated_list(COMMA, param) ")" body=body {
      Nodes.FlipDecl {
        params;
        ret_type;
        body;
      }
    }
  | "type" name=UIDENT params=ioption(delimited("<", separated_nonempty_list(",", generic_param), ">")) "=" value=type_expr {
      Nodes.TypeDecl {
        name;
        params;
        value;
      }
    }
  | "alias" name=UIDENT params=ioption(delimited("<", separated_nonempty_list(",", generic_param), ">")) "=" value=type_expr {
      Nodes.AliasDecl {
        name;
        params;
        value;
      }
    }

%inline ret_type:
  | ret_type=type_expr {
      Nodes.SafeRet ret_type
    }
  | safe_type=type_expr "?" abort_type=type_expr {
      Nodes.AbortRet (safe_type, abort_type)
    }

body:
  | "{" statements=list(stat) "}" {
      Nodes.Scope statements
    }
  | "=>" value=expr {
      Nodes.RetShorthand value
    }

func_call:
  | callee=expr "(" args=separated_list(COMMA, expr) ")" %prec LPAREN
      { Nodes.SafeCall { callee; args } }
  | callee=expr "(" args=separated_list(COMMA, expr) ")" "?" binder=ioption(LIDENT) body=body %prec LPAREN
      { Nodes.AbortCall { callee; args; binder; handle_block=Nodes.AbortBody body } }
  | callee=expr "(" args=separated_list(COMMA, expr) ")" "??" binder=ioption(LIDENT) value=expr %prec LPAREN
      { Nodes.AbortCall { callee; args; binder; handle_block=Nodes.AbortShorthand value } }

%inline if_:
  | IF cond=expr "{" block=list(stat) "}" {
      { Nodes.cond; block }
    }

%inline elif_:
  | ELIF cond=expr "{" block=list(stat) "}" {
      { Nodes.cond; block }
    }

%inline else_:
  | ELSE "{" statements=list(stat) "}" {
      statements
    }

%inline loop:
  | LOOP binder=LIDENT start=ioption(preceded(FROM, expr)) TO end_=expr "{" statements=list(stat) "}" {
      ({ start; end_; binder; body=statements; }: Nodes.loop)
    }

stat:
  | decl=decl { Nodes.DeclStat decl }
  | func_call=func_call {
      Nodes.FuncCallStat func_call
    }
  | ABORT value=expr {
      Nodes.AbortStat value
    }
  | RETURN value=expr {
      Nodes.RetStat value
    }
  | RESOLVE value=expr {
      Nodes.ResolveStat value
    }
  | if_=if_ elifs_=list(elif_) else_=ioption(else_) {
      Nodes.CondSeq { if_; elifs_; else_ }
    }
  | loop=loop {
      Nodes.Loop loop
    }

%inline param_type:
  | type_=type_expr {
      Nodes.NormalParam type_
    }
  | type_=name_type "<"
    generics=separated_nonempty_list(",", generic_param) ">" {
      Nodes.InfGenericParam {type_; generics}
    }
  | type_=generic_param_type {
      Nodes.GenericParam type_
    }

%inline param:
  | name=LIDENT type_=type_expr {
      ({ Nodes.name; type_=Nodes.NormalParam type_ }: Nodes.param)
    }
  | name=LIDENT type_=name_type "<"
    generics=separated_nonempty_list(",", generic_param) ">" {
      ({ Nodes.name; type_=Nodes.InfGenericParam {type_; generics}}: Nodes.param)
    }
  | name=UIDENT type_=generic_param_type {
      ({ Nodes.name; type_=Nodes.GenericParam type_ }: Nodes.param)
    }

%inline name_type:
  | name=UIDENT { Nodes.SimpleType name }
  | pkg=LIDENT "$" name=UIDENT { Nodes.QualifiedType (pkg, name) }

%inline call_type:
  | ret=ret_type "[" params=separated_list(",", param_type) "]" {
      Nodes.FuncType { params; ret_type=ret }
    }
  | ret=ret_type "[" THIS this_type=type_expr
    params=loption(preceded(",", separated_nonempty_list(",", param_type)))
    "]" is_mut=boption(MUT) {
      Nodes.MethType { this_type; params; ret_type=ret; is_mut }
    }

%inline body_field:
  | name=LIDENT type_=type_expr ";" {
      ({ Nodes.name; type_ } : Nodes.body_field)
    }

%inline body_type:
  | CLASS "{" fields=list(body_field) "}" {
      Nodes.Class fields
    }
  | STRUCT "{" fields=list(body_field) "}" {
      Nodes.Struct fields
    }
  | VARIANT "{" fields=list(body_field) "}" {
      Nodes.Variant fields
    }
  | ENUM "[" cases=separated_list(",", LIDENT) "]" {
      Nodes.Enum cases
    }
  | TUPLE "[" types=separated_list(",", type_expr) "]" {
      Nodes.Tuple types
    }


%inline generic_arg:
  | type_expr=type_expr {
      Nodes.TypeArg type_expr
    }
  | number=INT {
      Nodes.NumberArg number
    }


refable:
  | name_type=name_type {
      Nodes.NameType name_type
    }
  | name_type=name_type "<" params=separated_nonempty_list(",", generic_arg) ">" {
      Nodes.GenericType (name_type, params)
    }
  | body_type=body_type {
      Nodes.BodyType body_type
    }

type_expr:
  | call_type=call_type {
      Nodes.CallType call_type
    }
  | refable=refable {
      Nodes.NormalType refable
    }
  | "&" refable=refable {
      Nodes.RefType refable
    }

operator:
  | "+" { Nodes.Add }
  | "-" { Nodes.Sub }
  | "*" { Nodes.Mul }
  | "/" { Nodes.Div }
  | "=="{ Nodes.Eq }
  | "<="{ Nodes.LessEq }
  | ">="{ Nodes.MoreEq }
  | "<" { Nodes.Less }
  | ">" { Nodes.More }

expr:
  | int=INT { Nodes.IntLit int }
  | float=FLOAT { Nodes.FloatLit float }
  | string=STRING { Nodes.StrLit string }
  | TRUE { Nodes.BoolLit true }
  | FALSE { Nodes.BoolLit false }
  | ident=LIDENT { Nodes.Ident ident }
  | pkg=LIDENT "$" ident=LIDENT { Nodes.QualifiedIdent (pkg, ident) }
  | e1=expr "+"  e2=expr %prec PLUS   { Nodes.Op { left=e1; right=e2; operator=Nodes.Add } }
  | e1=expr "-"  e2=expr %prec MINUS  { Nodes.Op { left=e1; right=e2; operator=Nodes.Sub } }
  | e1=expr "*"  e2=expr %prec STAR   { Nodes.Op { left=e1; right=e2; operator=Nodes.Mul } }
  | e1=expr "/"  e2=expr %prec SLASH  { Nodes.Op { left=e1; right=e2; operator=Nodes.Div } }
  | e1=expr "==" e2=expr %prec EQEQ   { Nodes.Op { left=e1; right=e2; operator=Nodes.Eq } }
  | e1=expr "<=" e2=expr %prec LESSEQ { Nodes.Op { left=e1; right=e2; operator=Nodes.LessEq } }
  | e1=expr ">=" e2=expr %prec MOREEQ { Nodes.Op { left=e1; right=e2; operator=Nodes.MoreEq } }
  | e1=expr "<"  e2=expr %prec LESS   { Nodes.Op { left=e1; right=e2; operator=Nodes.Less } }
  | e1=expr ">"  e2=expr %prec MORE   { Nodes.Op { left=e1; right=e2; operator=Nodes.More } }
  | "~" value=expr %prec TILDE { Nodes.Flip value }
  | value=expr "." field=LIDENT %prec DOT { Nodes.DotAccess (value, field) }
  | type_=name_type "(" args=separated_list(COMMA, expr) ")" %prec LPAREN
      { Nodes.ConstructorCall { type_; args } }
  | "(" e=expr ")" { Nodes.Parenthized e }
  | func_call=func_call {
      Nodes.FuncCall func_call
    }
  | func_lambda=func_lambda {
      Nodes.FuncLambda func_lambda
    }
  | meth_lambda=meth_lambda {
      Nodes.MethLambda meth_lambda
    }
