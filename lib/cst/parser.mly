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
  | decls=list(decl) EOF { { Nodes.decls=decls } }

decl:
  | name=IDENT "(" params=separated_list(COMMA, param) ")" ret_type=type_expr body=function_body {
    Nodes.FunctionDecl { name; params; ret_type; body }
  }

function_body:
  | "{" statements=list(statement) "}" {
    Nodes.Scope statements
  }

statement:
  | callee=expr "(" args=separated_list(COMMA, expr) ")" {
    Nodes.FunctionCall { callee; args }
  }

param:
  | name=IDENT type_=type_expr { { Nodes.name; type_ } }

type_expr:
  | name=IDENT { Nodes.Simple name }

expr:
  | int=INT { Nodes.IntLiteral int }
  | float=FLOAT { Nodes.FloatLiteral float }
  | string=STRING { Nodes.StringLiteral string }
  | ident=IDENT { Nodes.Ident ident }
