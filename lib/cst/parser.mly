(*****************************)
(*     token definitions     *)
(*****************************)
%token <string> INT "43"
%token <string> FLOAT "8.647"
%token <string> STRING "\"john\""
%token <string> IDENT "foo"

%token LPAREN "("
%token RPAREN ")"
%token COMMA ","
%token LCURLY "{"
%token RCURLY "}"
%token LBRACKET "["
%token RBRACKET "]"
%token COLON
%token EQUAL "="
%token PLUS "+"
%token MINUS "-"
%token STAR "*"
%token SLASH "/"
%token DOLLAR "$"
%token AT "@"
%token EXCL "!"
%token QSTNMARK "?"
%token QSTNQSTN "??"
%token TILDE "~"
%token THIN_ARROW "->"
%token THICK_ARROW "=>"
%token THIS "this"
%token ERROR "<error>"
%token EOF "<eof>"

%left LPAREN
%left PLUS MINUS
%left STAR SLASH

%start <Nodes.package> package

(*************************)
(*     grammar rules     *)
(*************************)
%%

package:
  | decls=list(decl) EOF { { Nodes.decls=decls } }

decl:
  | name=IDENT type_=type_expr "=" value=expr {
      Nodes.VarDecl { name; type_; value }
    }
  | name=IDENT type_=type_expr "(" args=separated_list(COMMA, expr) ")" {
      Nodes.ConstructorDecl { name; type_; args }
    }
  | name=IDENT "(" params=separated_list(COMMA, param) ")" 
    ret_type=ret_type body=body {
      Nodes.FuncDecl { name; params; ret_type; body }
    }
  | name=IDENT "(" meth_params=meth_params ")"
    ret_type=ret_type body=body {
      Nodes.MethDecl { name; params=meth_params; ret_type; body; is_mut=false }
    }
  | name=IDENT "(" meth_params=meth_params ")" "!"
    ret_type=ret_type body=body {
      Nodes.MethDecl { name; params=meth_params; ret_type; body; is_mut=true }
    }

ret_type:
  | ret_type=type_expr {
      Nodes.SafeRet ret_type
    }
  | safe_type=type_expr "?" abort_type=type_expr {
    Nodes.AbortRet (safe_type, abort_type)
  }

meth_params:
  | THIS; t=type_expr; rest=loption(preceded(COMMA, separated_nonempty_list(COMMA, param)))
      { { Nodes.name="this"; type_=t } :: rest }

body:
  | "{" statements=list(stat) "}" {
      Nodes.Scope statements
    }

func_call:
  | callee=expr "(" args=separated_list(COMMA, expr) ")" {
      Nodes.SafeCall { callee; args }
    }
  | callee=expr "(" args=separated_list(COMMA, expr) ")" binder=ioption(IDENT) "?" body=body {
      Nodes.AbortCall { callee; args; binder; handle_block=Nodes.AbortBody body }
    }
  | callee=expr "(" args=separated_list(COMMA, expr) ")" binder=ioption(IDENT) "??" value=expr {
      Nodes.AbortCall { callee; args; binder; handle_block=Nodes.AbortShorthand value }
    }

stat:
  | decl=decl { Nodes.DeclStat decl }
  | func_call=func_call {
      Nodes.FuncCallStat func_call
    }


param:
  | name=IDENT type_=type_expr { { Nodes.name; type_ } }

type_expr:
  | name=IDENT { Nodes.SimpleType name }
  | "[" params=separated_list(COMMA, type_expr) "]" THIN_ARROW ret=type_expr {
      Nodes.FuncType { params; ret_type=ret }
    }
  | "[" THIS params=separated_list(COMMA, type_expr) "]" THIN_ARROW ret=type_expr {
      Nodes.MethType { params; ret_type=ret; is_mut=false }
    }
  | "[" THIS params=separated_list(COMMA, type_expr) "]" "!" THIN_ARROW ret=type_expr {
      Nodes.MethType { params; ret_type=ret; is_mut=true }
    }

expr:
  | int=INT { Nodes.IntLit int }
  | float=FLOAT { Nodes.FloatLit float }
  | string=STRING { Nodes.StrLit string }
  | ident=IDENT { Nodes.Ident ident }
  | e1=expr PLUS e2=expr  { Nodes.Op { left=e1; right=e2; operator="+" } }
  | e1=expr MINUS e2=expr { Nodes.Op { left=e1; right=e2; operator="-" } }
  | e1=expr STAR e2=expr  { Nodes.Op { left=e1; right=e2; operator="*" } }
  | e1=expr SLASH e2=expr { Nodes.Op { left=e1; right=e2; operator="/" } }
  | "(" e=expr ")" { Nodes.Parenthized e }
  | func_call=func_call {
      Nodes.FuncCall func_call
    }
