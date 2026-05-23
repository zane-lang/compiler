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
%type <std::unique_ptr<ast::nodes::Package>>                package
%type <std::unique_ptr<ast::nodes::Declaration>>            declaration
%type <std::unique_ptr<ast::nodes::FunctionDecl>>           function_decl
%type <std::vector<ast::nodes::Parameter>>                  parameters param_list
%type <std::unique_ptr<ast::nodes::Parameter>>              parameter
%type <std::unique_ptr<ast::nodes::TypeExpression>>         type_expr
%type <std::unique_ptr<ast::nodes::NameType>>               name_type
%type <std::unique_ptr<ast::nodes::FunctionType>>           function_type
%type <std::vector<std::unique_ptr<ast::nodes::TypeExpression>>> type_expr_list type_expr_list_ne
%type <std::unique_ptr<ast::nodes::Scope>>                  scope
%type <std::vector<std::unique_ptr<ast::nodes::Statement>>> statements
%type <std::unique_ptr<ast::nodes::Statement>>              statement
%type <std::unique_ptr<ast::nodes::FunctionCall>>           function_call
%type <std::unique_ptr<ast::nodes::ValueExpr>>              value_expr
%type <std::vector<std::unique_ptr<ast::nodes::ValueExpr>>> arguments arg_list

%%

package
	: %empty
		{
			$$ = std::make_unique<ast::nodes::Package>(std::vector<ast::nodes::Declaration>());
			ast = new ast::nodes::Package(*$$);
		}
	| package[pkg] declaration[decl]
		{
			auto declarations = std::move($pkg->declarations);
			declarations.push_back(std::move(*$decl));
			delete ast;
			$$ = std::make_unique<ast::nodes::Package>(std::move(declarations));
			ast = new ast::nodes::Package(*$$);
		}
	;

declaration
	: function_decl[fd]
		{ $$ = std::make_unique<ast::nodes::Declaration>(ast::nodes::Declaration(std::move(*$fd))); }
	;

function_decl
	: type_expr[return_type] IDENT[name] LPAREN parameters[params] RPAREN scope[body]
		{
			$$ = std::make_unique<ast::nodes::FunctionDecl>(ast::nodes::FunctionDecl(
				std::move($name),
				std::move($params),
				std::move(*$return_type),
				std::move(*$body),
				false
			));
		}
	;

parameters
	: %empty
		{ $$ = std::vector<ast::nodes::Parameter>(); }
	| param_list[list]
		{ $$ = std::move($list); }
	;

param_list
	: parameter[p]
		{
			$$ = std::vector<ast::nodes::Parameter>();
			$$.push_back(std::move(*$p));
		}
	| param_list[list] COMMA parameter[p]
		{ $list.push_back(std::move(*$p)); $$ = std::move($list); }
	;

parameter
	: IDENT[name] type_expr[type]
		{
			$$ = std::make_unique<ast::nodes::Parameter>(ast::nodes::Parameter(
				std::move($type),
				std::move($name)
			));
		}
	;

type_expr
	: name_type[nt]
		{ $$ = std::make_unique<ast::nodes::TypeExpression>(ast::nodes::TypeExpression(std::move(*$nt))); }
	;

// assumed syntax: Name or Name(T, U, ...) for generics
name_type
	: IDENT[id]
		{ $$ = std::make_unique<ast::nodes::NameType>(ast::nodes::NameType(std::move($id), {})); }
	;

type_expr_list
	: %empty
		{ $$ = std::vector<std::unique_ptr<ast::nodes::TypeExpression>>(); }
	| type_expr_list_ne[list]
		{ $$ = std::move($list); }
	;

type_expr_list_ne
	: type_expr[t]
		{
			$$ = std::vector<std::unique_ptr<ast::nodes::TypeExpression>>();
			$$.push_back(std::make_unique<ast::nodes::TypeExpression>($t.take()));
		}
	| type_expr_list_ne[list] COMMA type_expr[t]
		{ $list.push_back(std::make_unique<ast::nodes::TypeExpression>($t.take())); $$ = std::move($list); }
	;

scope
	: LCURLY statements[stmts] RCURLY
		{
			$$ = std::make_unique<ast::nodes::Scope>(ast::nodes::Scope(std::move($stmts)));
		}
	;

statements
	: %empty
		{ $$ = std::vector<std::unique_ptr<ast::nodes::Statement>>(); }
	| statements[list] statement[stmt]
		{
			$list.push_back(std::move($stmt));
			$$ = std::move($list);
		}
	| statements[list] statement[stmt] SEMICOLON
		{
			$list.push_back(std::move($stmt));
			$$ = std::move($list);
		}
	;

statement
	: function_call[fc]
		{ $$ = std::make_unique<ast::nodes::Statement>(ast::nodes::Statement(std::move(*$fc))); }
	;

// value_expr left-recursion handles chained calls: foo(a)(b)
value_expr
	: IDENT[id]
		{ $$ = std::make_unique<ast::nodes::ValueExpr>(ast::nodes::ValueExpr(ast::nodes::ValueSymbol(std::move($id)))); }
	| STRING[s]
		{ $$ = std::make_unique<ast::nodes::ValueExpr>(ast::nodes::ValueExpr(ast::nodes::StringLiteral(std::move($s)))); }
	| function_call[fc]
		{ $$ = std::make_unique<ast::nodes::ValueExpr>(ast::nodes::ValueExpr(std::move(*$fc))); }
	;

function_call
	: value_expr[callee] LPAREN arguments[args] RPAREN
		{
			$$ = std::make_unique<ast::nodes::FunctionCall>(ast::nodes::FunctionCall(
				std::move($callee),
				std::move($args)
			));
		}
	;

arguments
	: %empty
		{ $$ = std::vector<std::unique_ptr<ast::nodes::ValueExpr>>(); }
	| arg_list[list]
		{ $$ = std::move($list); }
	;

arg_list
	: value_expr[v]
		{
			$$ = std::vector<std::unique_ptr<ast::nodes::ValueExpr>>();
			$$.push_back(std::move($v));
		}
	| arg_list[list] COMMA value_expr[v]
		{ $list.push_back(std::move($v)); $$ = std::move($list); }
	;

%%

void yy::Parser::error(const location_type& loc, const std::string& msg) {
	std::cerr << loc.begin.line << ":" << loc.begin.column << ": " << msg << "\n";
}
