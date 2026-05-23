%skeleton "lalr1.cc"
%require "3.8"

%define api.parser.class { Parser }
%define api.namespace { yy }
%define api.value.type { ast::nodes::ValueNode* }

%{
	#include "ast/.hpp"
	#include <iostream>
	#include <string>
%}

%code {
	int yylex(yy::Parser::semantic_type* yylval, yy::Parser::location_type* yylloc,
			  const char*& cursor, const char*& marker, const char* limit,
			  ast::nodes::Program*& ast);
}

%locations
%param { const char*& cursor }
%param { const char*& marker }
%param { const char* limit }
%param { ast::nodes::Program*& ast }

%token INT
%token PLUS LPAREN RPAREN ERROR
%type expr
%destructor { delete $$; } INT expr
%left PLUS

%%
start: expr {
	ast = new ast::nodes::Program(std::unique_ptr<ast::nodes::ValueNode>($1));
	$1 = nullptr;
} ;

expr: INT {
	$$ = $1;
	$1 = nullptr;

}
| expr PLUS expr {
	$$ = new ast::nodes::ValueNode(ast::nodes::AddNode{
		std::unique_ptr<ast::nodes::ValueNode>($1),
		std::unique_ptr<ast::nodes::ValueNode>($3),
	});
	$1 = nullptr;
	$3 = nullptr;
}
| LPAREN expr RPAREN {
	$$ = $2;
	$2 = nullptr;
}
%%

void yy::Parser::error(const location& l, const std::string& m) {
	std::cerr << "Error at " << l.begin.line << ":" << l.begin.column << ": " << m << "\n";
}
