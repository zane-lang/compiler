(*****************************)
(*     token definitions     *)
(*****************************)
%token <string> INT FLOAT STRING IDENT
%token LPAREN "("
%token RPAREN ")"
%token COMMA ","
%token LCURLY "{"
%token RCURLY "}"
%token COLON ":"
%token EQUAL "="
%token PLUS "+"
%token MINUS "-"
%token STAR "*"
%token SLASH "/"
%token DOLLAR "$"
%token AT "@"
%token EXCL "!"
%token TILDE "~"
%token THIN_ARROW "->"
%token THICK_ARROW "=>"
%token THIS
%token ERROR
%token EOF

%left PLUS MINUS
%left STAR SLASH

%start <Nodes.package> package

(*************************)
(*     grammar rules     *)
(*************************)
%%

package:
  | decls=list(decl) EOF { { Nodes.decls = decls } }

decl:
  | name=IDENT "(" params=separated_list(COMMA, param) ")" 
    ret_type=type_expr body=func_body {
      Nodes.FuncDecl { name; params; ret_type; body }
    }
  | name=IDENT type_=type_expr "=" value=expr {
      Nodes.VarDecl { name; type_; value }
    }
  | name=IDENT type_=type_expr "(" args=separated_list(COMMA, expr) ")" {
      Nodes.ConstructorDecl { name; type_; args }
    }

func_body:
  | LCURLY statements=list(statement) RCURLY {
      Nodes.Scope statements
    }

statement:
  | callee=expr "(" args=separated_list(COMMA, expr) ")" {
      Nodes.FuncCallStat { callee; args }
    }

param:
  | name=IDENT type_=type_expr { { Nodes.name; type_ } }

type_expr:
  | name=IDENT { Nodes.SimpleType name }
  | "(" params=separated_list(COMMA, type_expr) ")" THIN_ARROW ret=type_expr {
      Nodes.FuncType { params; ret_type=ret }
    }
  | "(" THIS params=separated_list(COMMA, type_expr) ")" THIN_ARROW ret=type_expr {
      Nodes.MethType { params; ret_type=ret; is_mut=false }
    }
  | "(" THIS params=separated_list(COMMA, type_expr) ")" "!" THIN_ARROW ret=type_expr {
      Nodes.MethType { params; ret_type=ret; is_mut=true }
    }

expr:
  | p=primary { p }
  | e1=expr PLUS e2=expr  { Nodes.Op { left=e1; right=e2; operator="+" } }
  | e1=expr MINUS e2=expr { Nodes.Op { left=e1; right=e2; operator="-" } }
  | e1=expr STAR e2=expr  { Nodes.Op { left=e1; right=e2; operator="*" } }
  | e1=expr SLASH e2=expr { Nodes.Op { left=e1; right=e2; operator="/" } }
  | "(" e=expr ")" { Nodes.Parenthized e }
  | callee=expr "(" args=separated_list(COMMA, expr) ")" {
      Nodes.FuncCall { callee; args }
    }

primary:
  | int=INT { Nodes.IntLit int }
  | float=FLOAT { Nodes.FloatLit float }
  | string=STRING { Nodes.StrLit string }
  | ident=IDENT { Nodes.Ident ident }
