%skeleton "lalr1.cc"
%require "3.8"

%define api.parser.class { Parser }
%define api.namespace { yy }
%define api.value.type { ast::Node }

%{
    #include "ast/logic.hpp"
    #include <string>
    #include <memory>
%}

%code {
    int yylex(yy::Parser::semantic_type* yylval, yy::Parser::location_type* yylloc,
              const char*& cursor, const char*& marker, const char* limit);
}

%locations
%param { const char*& cursor }
%param { const char*& marker }
%param { const char* limit }

%token INT
%token PLUS LPAREN RPAREN ERROR
%type expr
%left PLUS

%%
start: expr ;

expr: INT { $$ = std::move($1); }
    | expr PLUS expr {
        $$ = ast::Node(ast::AddNode(
            std::make_unique<ast::Node>(std::move($1)),
            std::make_unique<ast::Node>(std::move($3))
        ));
      }
    | LPAREN expr RPAREN { $$ = std::move($2); }
    ;
%%

void yy::Parser::error(const location& l, const std::string& m) {
    std::cerr << "Error at " << l.begin.line << ":" << l.begin.column << ": " << m << "\n";
}
