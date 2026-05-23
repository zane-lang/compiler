%skeleton "lalr1.cc"
%require "3.8"
%define api.parser.class {Parser}
%define api.value.type variant
%define parse.error detailed
%locations

%code requires {
	#include "ast/.hpp"
	#include <iostream>
	#include <memory>
	#include <string>
	#include <vector>
}

%code {
	int yylex(
        yy::Parser::semantic_type* yylval, yy::Parser::location_type* yylloc,
        const char*& cursor, const char*& marker, const char* limit,
        ast::nodes::Package*& ast);
}

%param { const char*& cursor }
%param { const char*& marker }
%param { const char* limit }
%param { ast::nodes::Package*& ast }

// --- tokens ---
%token LPAREN RPAREN LCURLY RCURLY
%token COMMA COLON SEMICOLON
%token <std::string> STRING IDENT
%token ERROR

// --- non-terminal types ---
%type <ast::nodes::Package>                                 package
%type <ast::nodes::Declaration>                             declaration
%type <ast::nodes::FunctionDecl>                            function_decl
%type <std::vector<ast::nodes::Parameter>>                  parameters param_list
%type <ast::nodes::Parameter>                               parameter
%type <ast::nodes::TypeExpression>                          type_expr
%type <ast::nodes::NameType>                                name_type
%type <ast::nodes::FunctionType>                            function_type
%type <std::vector<ast::nodes::TypeExpression>>             type_expr_list type_expr_list_ne
%type <ast::nodes::Scope>                                   scope
%type <std::vector<std::unique_ptr<ast::nodes::Statement>>> statements
%type <ast::nodes::Statement>                               statement
%type <ast::nodes::FunctionCall>                            function_call
%type <ast::nodes::ValueExpr>                               value_expr
%type <std::vector<ast::nodes::ValueExpr>>                  arguments arg_list

%%

package
	: %empty
		{ $$ = ast::nodes::Package(); }
	| package[pkg] declaration[decl]
		{ $pkg.declarations.push_back(std::move($decl)); $$ = std::move($pkg); }
	;

declaration
	: function_decl[fd]
		{ $$ = ast::nodes::Declaration(std::move($fd)); }
	;

function_decl
	: type_expr[return_type] IDENT[name] LPAREN parameters[params] RPAREN scope[body]
		{
			$$ = ast::nodes::FunctionDecl{
				std::move($name),
				std::move($params),
				std::move($return_type),
				std::move($body),
				false
			};
		}
	;

parameters
	: %empty
		{ $$ = {}; }
	| param_list[list]
		{ $$ = std::move($list); }
	;

param_list
	: parameter[p]
		{ $$ = {std::move($p)}; }
	| param_list[list] COMMA parameter[p]
		{ $list.push_back(std::move($p)); $$ = std::move($list); }
	;

parameter
	: IDENT[name] type_expr[type]
		{
			$$ = ast::nodes::Parameter{
				std::make_unique<ast::nodes::TypeExpression>(std::move($type)),
				std::move($name)
			};
		}
	;

type_expr
	: name_type[nt]
		{ $$ = ast::nodes::TypeExpression{ std::move($nt) }; }
	;

// assumed syntax: Name or Name(T, U, ...) for generics
name_type
	: IDENT[id]
		{ $$ = ast::nodes::NameType{ std::move($id), {} }; }
	;

type_expr_list
	: %empty
		{ $$ = {}; }
	| type_expr_list_ne[list]
		{ $$ = std::move($list); }
	;

type_expr_list_ne
	: type_expr[t]
		{ $$ = {std::move($t)}; }
	| type_expr_list_ne[list] COMMA type_expr[t]
		{ $list.push_back(std::move($t)); $$ = std::move($list); }
	;

scope
	: LCURLY statements[stmts] RCURLY
		{
			ast::nodes::Scope s;
			s.statements = std::move($stmts);
			$$ = std::move(s);
		}
	;

statements
	: %empty
		{ $$ = {}; }
	| statements[list] statement[stmt] SEMICOLON
		{
			$list.push_back(std::make_unique<ast::nodes::Statement>(std::move($stmt)));
			$$ = std::move($list);
		}
	;

statement
	: function_call[fc]
		{ $$ = ast::nodes::Statement{ std::move($fc) }; }
	;

// value_expr left-recursion handles chained calls: foo(a)(b)
value_expr
	: IDENT[id]
		{ $$ = ast::nodes::ValueExpr{ ast::nodes::ValueSymbol{ std::move($id) } }; }
	| STRING[s]
		{ $$ = ast::nodes::ValueExpr{ ast::nodes::StringLiteral{ std::move($s) } }; }
	| function_call[fc]
		{ $$ = ast::nodes::ValueExpr{ std::move($fc) }; }
	;

function_call
	: value_expr[callee] LPAREN arguments[args] RPAREN
		{
			$$ = ast::nodes::FunctionCall{
				std::make_unique<ast::nodes::ValueExpr>(std::move($callee)),
				std::move($args)
			};
		}
	;

arguments
	: %empty
		{ $$ = {}; }
	| arg_list[list]
		{ $$ = std::move($list); }
	;

arg_list
	: value_expr[v]
		{ $$ = {std::move($v)}; }
	| arg_list[list] COMMA value_expr[v]
		{ $list.push_back(std::move($v)); $$ = std::move($list); }
	;

%%

void yy::Parser::error(const location_type& loc, const std::string& msg) {
	std::cerr << loc.begin.line << ":" << loc.begin.column << ": " << msg << "\n";
}
