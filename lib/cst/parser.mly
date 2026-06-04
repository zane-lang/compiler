%token <string> INT FLOAT STRING IDENT
%token EQUAL
%token LPAREN RPAREN
%token LCURLY RCURLY
%token COMMA COLON
%token EXCL TILDE
%token PLUS MINUS STAR SLASH
%token DOLLAR AT
%token THIN_ARROW THICK_ARROW
%token THIS
%token ERROR
%token EOF

%left PLUS MINUS
%left STAR SLASH

%start <Nodes.package> package
%%

package:
  | decls = list(decl) EOF { { Nodes.decls = decls } }

decl:
  | name = IDENT LPAREN params = separated_list(COMMA, param) RPAREN ret_type = type_expr
  { Nodes.FunctionDecl { name; params; ret_type } }

param:
  | name = IDENT type_ = type_expr { { Nodes.name; type_ } }

type_expr:
  | name = IDENT { Nodes.Simple name }
