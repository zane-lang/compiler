%skeleton "lalr1.cc"
%require "3.8"

%define api.parser.class { Parser }
%define api.namespace { yy }
%define api.value.type { ast::Node }

%code requires {
    #include "ast/logic.hpp"
    #include <string>
    #include <memory>
}

%locations
%param { const char*& cursor }
%param { const char*& marker }
%param { const char* limit }

%token <int> INT
%token PLUS LPAREN RPAREN END ERROR
%type <ast::Node> expr
%left PLUS

%%
start: expr END ;

expr: INT { $$ = ast::IntNode{$1}; }
    | expr PLUS expr {
        $$ = ast::AddNode{
            std::make_unique<ast::Node>(std::move($1)),
            std::make_unique<ast::Node>(std::move($3))
        };
      }
    | LPAREN expr RPAREN { $$ = std::move($2); }
    ;
%%

void yy::Parser::error(const location& l, const std::string& m) {
    std::cerr << "Error at " << l.begin.line << ":" << l.begin.column << ": " << m << "\n";
}
