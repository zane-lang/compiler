%token <int> INT
%token PLUS MINUS MUL DIV LPAREN RPAREN EOF

%left PLUS MINUS
%left MUL DIV

%start <Nodes.expr> prog
%%
prog:
  | e = expr EOF { e }

expr:
  | i = INT { Nodes.Int i }
  | LPAREN e = expr RPAREN { e }
  | e1 = expr PLUS e2 = expr { Nodes.Add (e1, e2) }
  | e1 = expr MINUS e2 = expr { Nodes.Sub (e1, e2) }
  | e1 = expr MUL e2 = expr { Nodes.Mul (e1, e2) }
  | e1 = expr DIV e2 = expr { Nodes.Div (e1, e2) }
