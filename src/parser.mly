%token <int> INT
%token PLUS MINUS MUL DIV LPAREN RPAREN EOF

%left PLUS MINUS
%left MUL DIV

%start <Ast.expr> prog
%%
prog:
  | e = expr EOF { e }

expr:
  | i = INT { Ast.Int i }
  | LPAREN e = expr RPAREN { e }
  | e1 = expr PLUS e2 = expr { Ast.Add (e1, e2) }
  | e1 = expr MINUS e2 = expr { Ast.Sub (e1, e2) }
  | e1 = expr MUL e2 = expr { Ast.Mul (e1, e2) }
  | e1 = expr DIV e2 = expr { Ast.Div (e1, e2) }
