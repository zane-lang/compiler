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
%token COMMA COLON LINE_BREAK
%token TILDE
%token <std::string> STRING IDENT INT FLOAT
%token ERROR

// --- associativity ---
%left <std::string> PLUS MINUS
%left <std::string> STAR SLASH
%right TILDE

// --- non-terminal types ---
%type <std::unique_ptr<ast::nodes::Package>>                package
%type <std::vector<ast::nodes::Declaration>>                global_scope
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
%type <std::unique_ptr<ast::nodes::OperatorCall>>           operator_call
%type <std::unique_ptr<ast::nodes::OperatorFlipCall>>       operator_flip_call
%type <std::unique_ptr<ast::nodes::FunctionCall>>           function_call
%type <std::unique_ptr<ast::nodes::ParenthizedValue>>       parenthized_value
%type <std::unique_ptr<ast::nodes::ValueExpr>>              value_expr
%type <std::vector<std::unique_ptr<ast::nodes::ValueExpr>>> arguments arg_list

%%

package
	: may_break global_scope[glb] may_break
		{
			$$ = std::make_unique<ast::nodes::Package>(std::move($glb));
			ast = new ast::nodes::Package(*$$);
		}
	;

may_break
	: %empty
	| LINE_BREAK
	;

global_scope
	: declaration[decl] 
		{
			auto declarations = std::vector<ast::nodes::Declaration>();
			declarations.push_back(std::move(*$decl));
			$$ = std::move(declarations);
		}
	| global_scope[glb] LINE_BREAK declaration[decl]
		{
			$glb.push_back(std::move(*$decl));
			$$ = std::move($glb);
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
	;

statement
	: function_call[fc]
		{ $$ = std::make_unique<ast::nodes::Statement>(ast::nodes::Statement(std::move(*$fc))); }
	;

// value_expr left-recursion handles chained calls: foo(a)(b)
value_expr
	: IDENT[id]
		{ $$ = std::make_unique<ast::nodes::ValueExpr>(ast::nodes::ValueExpr(ast::nodes::ValueSymbol(std::move($id)))); }
	| INT[i]
		{ $$ = std::make_unique<ast::nodes::ValueExpr>(ast::nodes::ValueExpr(ast::nodes::IntLiteral(std::move($i)))); }
	| FLOAT[f]
		{ $$ = std::make_unique<ast::nodes::ValueExpr>(ast::nodes::ValueExpr(ast::nodes::FloatLiteral(std::move($f)))); }
	| STRING[s]
		{ $$ = std::make_unique<ast::nodes::ValueExpr>(ast::nodes::ValueExpr(ast::nodes::StringLiteral(std::move($s)))); }
	| function_call[fc]
		{ $$ = std::make_unique<ast::nodes::ValueExpr>(ast::nodes::ValueExpr(std::move(*$fc))); }
	| operator_call[op]
		{ $$ = std::make_unique<ast::nodes::ValueExpr>(ast::nodes::ValueExpr(std::move(*$op))); }
	| operator_flip_call[op_flip]
		{ $$ = std::make_unique<ast::nodes::ValueExpr>(ast::nodes::ValueExpr(std::move(*$op_flip))); }
	| parenthized_value[pv]
		{ $$ = std::make_unique<ast::nodes::ValueExpr>(ast::nodes::ValueExpr(std::move(*$pv))); }
	;

parenthized_value
	: LPAREN value_expr[val] RPAREN
		{
			$$ = std::make_unique<ast::nodes::ParenthizedValue>(
				ast::nodes::ParenthizedValue(std::move($val))
			);
		}
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

operator_flip_call
	: TILDE value_expr[value]
		{
			$$ = std::make_unique<ast::nodes::OperatorFlipCall>(ast::nodes::OperatorFlipCall(
				std::move($value)
			));
		}
	;

operator_call
	: value_expr[left] PLUS[op] value_expr[right]
		{
			$$ = std::make_unique<ast::nodes::OperatorCall>(ast::nodes::OperatorCall(
				std::move($op),
				std::move($left),
				std::move($right)
			));
		}
	| value_expr[left] MINUS[op] value_expr[right]
		{
			$$ = std::make_unique<ast::nodes::OperatorCall>(ast::nodes::OperatorCall(
				std::move($op),
				std::move($left),
				std::move($right)
			));
		}
	| value_expr[left] STAR[op] value_expr[right]
		{
			$$ = std::make_unique<ast::nodes::OperatorCall>(ast::nodes::OperatorCall(
				std::move($op),
				std::move($left),
				std::move($right)
			));
		}
	| value_expr[left] SLASH[op] value_expr[right]
		{
			$$ = std::make_unique<ast::nodes::OperatorCall>(ast::nodes::OperatorCall(
				std::move($op),
				std::move($left),
				std::move($right)
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

template <typename Ret, typename U>
std::unique_ptr<Ret> wrap(U&& val) {
   return std::make_unique<Ret>(std::forward<U>(val));
}

void yy::Parser::error(const location_type& loc, const std::string& msg) {
	std::cerr << loc.begin.line << ":" << loc.begin.column << ": " << msg << "\n";
}
