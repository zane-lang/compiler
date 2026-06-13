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
%token COLON
%token EQUAL       "="
%token PLUS        "+"
%token MINUS       "-"
%token STAR        "*"
%token SLASH       "/"
%token DOLLAR      "$"
%token AT          "@"
%token EXCL        "!"
%token QSTNMARK    "?"
%token QSTNQSTN    "??"
%token TILDE       "~"
%token THIN_ARROW  "->"
%token THICK_ARROW "=>"
%token EQEQ        "=="
%token LESSEQ      "<="
%token MOREEQ      ">="
%token LESS        "<"
%token MORE        ">"
%token IF          "if"
%token ELIF        "elif"
%token ELSE        "else"
%token TRUE        "true"
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
    ")" body=body {
      { Nodes.this_type; params; ret_type; is_mut=false; body }
    }
  | ret_type=ret_type "(" THIS this_type=type_expr
    params=loption(preceded(",", separated_nonempty_list(",", param)))
    ")" MUT body=body {
      { Nodes.this_type; params; ret_type; is_mut=true; body }
    }

decl:
  | name=LIDENT type_=type_expr "=" value=expr {
      Nodes.VarDecl { name; type_; value }
    }
  | name=LIDENT type_=type_expr "(" args=separated_list(COMMA, expr) ")" {
      Nodes.ConstructorDecl { name; type_; args }
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

%inline param:
  | name=LIDENT type_=type_expr { { Nodes.name; type_ } }

type_expr:
  | name=UIDENT { Nodes.SimpleType name }
  | pkg=UIDENT name=UIDENT { Nodes.QualifiedType (pkg, name) }
  | ret=ret_type "[" params=separated_list(",", type_expr) "]" {
      Nodes.FuncType { params; ret_type=ret }
    }
  | ret=ret_type "[" THIS this_type=type_expr 
    params=loption(preceded(",", separated_nonempty_list(",", type_expr)))
    "]" {
      Nodes.MethType { this_type; params; ret_type=ret; is_mut=false }
    }
  | ret=ret_type "[" THIS this_type=type_expr
    params=loption(preceded(",", separated_nonempty_list(",", type_expr)))
    "]" MUT {
      Nodes.MethType { this_type; params; ret_type=ret; is_mut=true }
    }

expr:
  | int=INT { Nodes.IntLit int }
  | float=FLOAT { Nodes.FloatLit float }
  | string=STRING { Nodes.StrLit string }
  | TRUE { Nodes.BoolLit true }
  | FALSE { Nodes.BoolLit false }
  | ident=LIDENT { Nodes.Ident ident }
  | pkg=UIDENT "$" ident=LIDENT { Nodes.QualifiedIdent (pkg, ident) }
  | e1=expr "+" e2=expr  { Nodes.Op { left=e1; right=e2; operator=Nodes.Add } }
  | e1=expr "-" e2=expr { Nodes.Op { left=e1; right=e2; operator=Nodes.Sub } }
  | e1=expr "*" e2=expr  { Nodes.Op { left=e1; right=e2; operator=Nodes.Mul } }
  | e1=expr "/" e2=expr { Nodes.Op { left=e1; right=e2; operator=Nodes.Div } }
  | e1=expr "==" e2=expr { Nodes.Op { left=e1; right=e2; operator=Nodes.Eq } }
  | e1=expr "<=" e2=expr { Nodes.Op { left=e1; right=e2; operator=Nodes.LessEq } }
  | e1=expr ">=" e2=expr { Nodes.Op { left=e1; right=e2; operator=Nodes.MoreEq } }
  | e1=expr "<" e2=expr { Nodes.Op { left=e1; right=e2; operator=Nodes.Less } }
  | e1=expr ">" e2=expr { Nodes.Op { left=e1; right=e2; operator=Nodes.More } }
  | "~" value=expr %prec TILDE { Nodes.Flip value }
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
