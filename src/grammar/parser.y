%skeleton "lalr1.cc"
%require "3.8"
%define api.parser.class {Parser}
%define api.value.type variant
%define parse.error detailed
%locations
%start package

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
		ast::nodes::Package*& ast, int& line, const char*& line_start);
}

%param { const char*& cursor }
%param { const char*& marker }
%param { const char* limit }
%param { ast::nodes::Package*& ast }
%param { int& line }
%param { const char*& line_start }

// --- tokens ---
%token LPAREN RPAREN LCURLY RCURLY
%token COMMA COLON
%token DOLLAR THIN_ARROW AT
%token <std::string> STRING IDENT INT FLOAT
%token ERROR

// --- associativity ---
%left <std::string> PLUS MINUS
%left <std::string> STAR SLASH
%right TILDE

// --- non-terminal types ---
%type <ast::nodes::Package>                                 package
%type <std::vector<ast::nodes::Declaration>>                global_scope
%type <ast::nodes::Declaration>                             declaration
%type <ast::nodes::FunctionDecl>                            function_decl
%type <std::vector<ast::nodes::Parameter>>                  parameters
%type <ast::nodes::Parameter>                               parameter
%type <ast::nodes::TypeExpression>                          type_expr
%type <ast::nodes::NameType>                                name_type
%type <ast::nodes::FunctionType>                            function_type
%type <ast::nodes::Scope>                                   scope
%type <std::vector<std::unique_ptr<ast::nodes::Statement>>> statements
%type <ast::nodes::Statement>                               statement
%type <ast::nodes::OperatorCall>                            operator_call
%type <ast::nodes::OperatorFlipCall>                        operator_flip_call
%type <ast::nodes::FunctionCall>                            function_call
%type <ast::nodes::ParenthizedValue>                        parenthized_value
%type <ast::nodes::ValueExpr>                               value_expr
%type <std::vector<std::unique_ptr<ast::nodes::ValueExpr>>> arguments arg_list

%%

package
	: global_scope[glb]
		{
			$$ = ast::nodes::Package(std::move($glb));
			ast = new ast::nodes::Package(std::move($$));
		}
	;

global_scope
	: %empty
	| global_scope[glb] declaration[decl]
		{
			$glb.push_back(std::move($decl));
			$$ = std::move($glb);
		}
	;

declaration
	: function_decl[fd]
		{ $$ = ast::nodes::Declaration(std::move($fd)); }
	;

function_decl
	: type_expr[return_type] IDENT[name] LPAREN parameters[params] RPAREN scope[body]
		{
			$$ = ast::nodes::FunctionDecl(
				std::move($name),
				std::move($params),
				std::move($return_type),
				std::move($body),
				false
			);
		}
	;

parameters
	: %empty
	| parameters[params] COMMA parameter[p]
		{
			$params.push_back(std::move($p));
			$$ = std::move($params);
		}
	;

parameter
	: IDENT[name] type_expr[type]
		{
			$$ = ast::nodes::Parameter(
				std::make_unique<ast::nodes::TypeExpression>(std::move($type)),
				std::move($name)
			);
		}
	;

function_type
	: LPAREN parameters[params] RPAREN THIN_ARROW type_expr[ret_type]
		{
			$$ = ast::nodes::FunctionType(
				std::move($params),
				std::make_unique<ast::nodes::TypeExpression>(std::move($ret_type))
			);
		}
	;

type_expr
	: name_type[nt]
		{ $$ = ast::nodes::TypeExpression(std::move($nt)); }
	| function_type[ft]
		{ $$ = ast::nodes::TypeExpression(std::move($ft)); }
	;

name_type
	: IDENT[id]
		{ $$ = ast::nodes::NameType(std::move($id), std::vector<std::unique_ptr<ast::nodes::TypeExpression>>()); }
	;

scope
	: LCURLY statements[stmts] RCURLY
		{ $$ = ast::nodes::Scope(std::move($stmts)); }
	;

statements
	: %empty
		{ $$ = std::vector<std::unique_ptr<ast::nodes::Statement>>(); }
	| statements[list] statement[stmt]
		{
			$list.push_back(std::make_unique<ast::nodes::Statement>(std::move($stmt)));
			$$ = std::move($list);
		}
	;

statement
	: function_call[fc]
		{ $$ = ast::nodes::Statement(std::move($fc)); }
	;

value_expr
	: IDENT[id]
		{ $$ = ast::nodes::ValueExpr(ast::nodes::ValueSymbol(std::move($id))); }
	| IDENT[pkg] DOLLAR IDENT[id]
		{ $$ = ast::nodes::ValueExpr(ast::nodes::PackageValueSymbol(std::move($id), std::move($pkg))); }
	| AT IDENT[pkg] DOLLAR IDENT[id]
		{ $$ = ast::nodes::ValueExpr(ast::nodes::IntrinsicValueSymbol(std::move($id), std::move($pkg))); }
	| INT[i]
		{ $$ = ast::nodes::ValueExpr(ast::nodes::IntLiteral(std::move($i))); }
	| FLOAT[f]
		{ $$ = ast::nodes::ValueExpr(ast::nodes::FloatLiteral(std::move($f))); }
	| STRING[s]
		{ $$ = ast::nodes::ValueExpr(ast::nodes::StringLiteral(std::move($s))); }
	| function_call[fc]
		{ $$ = ast::nodes::ValueExpr(std::move($fc)); }
	| operator_call[op]
		{ $$ = ast::nodes::ValueExpr(std::move($op)); }
	| operator_flip_call[op_flip]
		{ $$ = ast::nodes::ValueExpr(std::move($op_flip)); }
	| parenthized_value[pv]
		{ $$ = ast::nodes::ValueExpr(std::move($pv)); }
	;

parenthized_value
	: LPAREN value_expr[val] RPAREN
		{ $$ = ast::nodes::ParenthizedValue(std::make_unique<ast::nodes::ValueExpr>(std::move($val))); }
	;

function_call
	: value_expr[callee] LPAREN arguments[args] RPAREN
		{
			$$ = ast::nodes::FunctionCall(
				std::make_unique<ast::nodes::ValueExpr>(std::move($callee)),
				std::move($args)
			);
		}
	;

operator_flip_call
	: TILDE value_expr[value]
		{ $$ = ast::nodes::OperatorFlipCall(std::make_unique<ast::nodes::ValueExpr>(std::move($value))); }
	;

operator_call
	: value_expr[left] PLUS[op] value_expr[right]
		{ $$ = ast::nodes::OperatorCall(std::move($op), std::make_unique<ast::nodes::ValueExpr>(std::move($left)), std::make_unique<ast::nodes::ValueExpr>(std::move($right))); }
	| value_expr[left] MINUS[op] value_expr[right]
		{ $$ = ast::nodes::OperatorCall(std::move($op), std::make_unique<ast::nodes::ValueExpr>(std::move($left)), std::make_unique<ast::nodes::ValueExpr>(std::move($right))); }
	| value_expr[left] STAR[op] value_expr[right]
		{ $$ = ast::nodes::OperatorCall(std::move($op), std::make_unique<ast::nodes::ValueExpr>(std::move($left)), std::make_unique<ast::nodes::ValueExpr>(std::move($right))); }
	| value_expr[left] SLASH[op] value_expr[right]
		{ $$ = ast::nodes::OperatorCall(std::move($op), std::make_unique<ast::nodes::ValueExpr>(std::move($left)), std::make_unique<ast::nodes::ValueExpr>(std::move($right))); }
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
			$$.push_back(std::make_unique<ast::nodes::ValueExpr>(std::move($v)));
		}
	| arg_list[list] COMMA value_expr[v]
		{ $list.push_back(std::make_unique<ast::nodes::ValueExpr>(std::move($v))); $$ = std::move($list); }
	;

%%

void yy::Parser::error(const location_type& loc, const std::string& msg) {
	std::cerr << loc.begin.line << ":" << loc.begin.column << ": " << msg << "\n";
}
