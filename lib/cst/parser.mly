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
  | name=IDENT LPAREN params=separated_list(COMMA, param) RPAREN 
    ret_type=type_expr body=function_body {
      Nodes.FunctionDecl { name; params; ret_type; body }
    }

function_body:
  | LCURLY statements=list(statement) RCURLY {
      Nodes.Scope statements
    }

statement:
  | expr=expr
      { Nodes.ExprStatement expr }

param:
  | name=IDENT type_=type_expr { { Nodes.name; type_ } }

type_expr:
  | name=IDENT { Nodes.SimpleType name }
  | LPAREN params=separated_list(COMMA, type_expr) RPAREN THIN_ARROW ret=type_expr {
      Nodes.FunctionType { params; ret_type=ret }
    }
  | LPAREN params=separated_list(COMMA, type_expr) RPAREN THICK_ARROW ret=type_expr {
      Nodes.MethodType { params; ret_type=ret; is_mut=false }
    }
  | EXCL LPAREN params=separated_list(COMMA, type_expr) RPAREN THICK_ARROW ret=type_expr {
      Nodes.MethodType { params; ret_type=ret; is_mut=true }
    }

expr:
  | e1=expr PLUS e2=expr  { Nodes.Operator { left=e1; right=e2; operator="+" } }
  | e1=expr MINUS e2=expr { Nodes.Operator { left=e1; right=e2; operator="-" } }
  | e1=expr STAR e2=expr  { Nodes.Operator { left=e1; right=e2; operator="*" } }
  | e1=expr SLASH e2=expr { Nodes.Operator { left=e1; right=e2; operator="/" } }
  | p=primary { p }

primary:
  | int=INT { Nodes.IntLiteral int }
  | float=FLOAT { Nodes.FloatLiteral float }
  | string=STRING { Nodes.StringLiteral string }
  | ident=IDENT { Nodes.Ident ident }
  | LPAREN e=expr RPAREN { Nodes.Parenthized e }
  | callee=primary LPAREN args=separated_list(COMMA, expr) RPAREN {
      Nodes.FunctionCall { callee; args }
    }
