%skeleton "lalr1.cc"
%require "3.8"
%define api.parser.class {Parser}
%define api.value.type variant
%define parse.error detailed
%locations
%start package

%code requires {
	#include "ast/.hpp"
	#include <algorithm>
	#include <iostream>
	#include <memory>
	#include <string>
	#include <vector>
}

%code {
	int yylex(
		yy::Parser::semantic_type* yylval, yy::Parser::location_type* yylloc,
		const char*& cursor, const char*& marker, const char* limit,
		const std::string& sourcePath, const std::string& source, ast::nodes::Package*& ast, int& line, const char*& line_start);
}

%param { const char*& cursor }
%param { const char*& marker }
%param { const char* limit }

%param { const std::string& sourcePath }
%param { const std::string& source }
%param { ast::nodes::Package*& ast }
%param { int& line }
%param { const char*& line_start }

// --- tokens ---
%token LPAREN RPAREN LCURLY RCURLY
%token COMMA COLON EQUAL
%token DOLLAR THIN_ARROW AT
%token MUT THIS
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
%type <ast::nodes::VariableDecl>                            variable_decl
%type <ast::nodes::FunctionDecl>                            function_decl
%type <ast::nodes::MethodDecl>                              method_decl
%type <std::vector<ast::nodes::Parameter>>                  parameters method_parameters
%type <std::vector<std::unique_ptr<ast::nodes::TypeExpression>>> type_list type_list_ne
%type <ast::nodes::Parameter>                               parameter
%type <ast::nodes::TypeExpression>                          type_expr
%type <ast::nodes::NameType>                                name_type
%type <ast::nodes::FunctionType>                            function_type
%type <ast::nodes::MethodType>                              method_type
%type <ast::nodes::Scope>                                   scope
%type <std::vector<std::unique_ptr<ast::nodes::Statement>>> statements
%type <ast::nodes::Statement>                               statement
%type <ast::nodes::OperatorCall>                            operator_call
%type <ast::nodes::OperatorFlipCall>                        operator_flip_call
%type <ast::nodes::FunctionCall>                            function_call
%type <ast::nodes::FunctionCall>                            statement_function_call
%type <ast::nodes::ParenthizedValue>                        parenthized_value
%type <ast::nodes::ValueExpr>                               value_expr
%type <std::vector<std::unique_ptr<ast::nodes::ValueExpr>>> arguments

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
		{ $$ = std::vector<ast::nodes::Declaration>(); }
	| global_scope[glb] declaration[decl]
		{
			$glb.push_back(std::move($decl));
			$$ = std::move($glb);
		}
	;

declaration
	: function_decl[fd]
		{ $$ = ast::nodes::Declaration(std::move($fd)); }
	| method_decl[md]
		{ $$ = ast::nodes::Declaration(std::move($md)); }
	;

variable_decl
	: IDENT[name] type_expr[type] EQUAL value_expr[val]
		{
			$$ = ast::nodes::VariableDecl(
				std::move($name),
				std::move($type),
				std::make_unique<ast::nodes::ValueExpr>(std::move($val))
			);
		}
	;

function_decl
	: type_expr[return_type] IDENT[name] LPAREN parameters[params] RPAREN scope[body]
		{
			$$ = ast::nodes::FunctionDecl(
				std::move($name),
				std::move($params),
				std::move($return_type),
				std::move($body)
			);
		}
	;

method_decl
	: type_expr[return_type] IDENT[name] LPAREN method_parameters[params] RPAREN scope[body]
		{
			$$ = ast::nodes::MethodDecl(
				std::move($name),
				std::move($params),
				std::move($return_type),
				std::move($body),
				false
			);
		}
	
	| type_expr[return_type] IDENT[name] LPAREN method_parameters[params] RPAREN MUT scope[body]
		{
			$$ = ast::nodes::MethodDecl(
				std::move($name),
				std::move($params),
				std::move($return_type),
				std::move($body),
				true
			);
		}
	;

method_parameters
	: %empty
		{ $$ = std::vector<ast::nodes::Parameter>(); }
	| THIS type_expr[type]
		{
			$$ = std::vector<ast::nodes::Parameter>();
			$$.push_back(std::move(
				ast::nodes::Parameter(
					std::make_unique<ast::nodes::TypeExpression>(std::move($type)),
					"this"
				)
			));
		}
	| method_parameters[params] COMMA parameter[p]
		{
			$params.push_back(std::move($p));
			$$ = std::move($params);
		}
	;

parameters
	: %empty
		{ $$ = std::vector<ast::nodes::Parameter>(); }
	| parameter[p]
		{
			$$ = std::vector<ast::nodes::Parameter>();
			$$.push_back(std::move($p));
		}
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

type_list
	: %empty
		{ $$ = std::vector<std::unique_ptr<ast::nodes::TypeExpression>>(); }
	| type_expr[expr]
		{
			$$ = std::vector<std::unique_ptr<ast::nodes::TypeExpression>>();
			$$.push_back(std::make_unique<ast::nodes::TypeExpression>(std::move($expr)));
		}
	| type_list[list] COMMA type_expr[expr]
		{
			$list.push_back(std::make_unique<ast::nodes::TypeExpression>(std::move($expr)));
			$$ = std::move($list);
		}
	;

type_list_ne
	: type_expr[expr]
		{
			$$ = std::vector<std::unique_ptr<ast::nodes::TypeExpression>>();
			$$.push_back(std::make_unique<ast::nodes::TypeExpression>(std::move($expr)));
		}
	| type_list[list] COMMA type_expr[expr]
		{
			$list.push_back(std::make_unique<ast::nodes::TypeExpression>(std::move($expr)));
			$$ = std::move($list);
		}
	;

function_type
	: LPAREN type_list[params] RPAREN THIN_ARROW type_expr[ret_type]
		{
			$$ = ast::nodes::FunctionType(
				std::move($params),
				std::make_unique<ast::nodes::TypeExpression>(std::move($ret_type))
			);
		}
	;

method_type
	: LPAREN THIS type_list_ne[params] RPAREN THIN_ARROW type_expr[ret_type]
		{
			$$ = ast::nodes::MethodType(
				std::move($params),
				std::make_unique<ast::nodes::TypeExpression>(std::move($ret_type)),
				false
			);
		}
	| LPAREN THIS type_list_ne[params] RPAREN MUT THIN_ARROW type_expr[ret_type]
		{
			$$ = ast::nodes::MethodType(
				std::move($params),
				std::make_unique<ast::nodes::TypeExpression>(std::move($ret_type)),
				true
			);
		}
	;

type_expr
	: name_type[nt]
		{ $$ = ast::nodes::TypeExpression(std::move($nt)); }
	| function_type[ft]
		{ $$ = ast::nodes::TypeExpression(std::move($ft)); }
	| method_type[mt]
		{ $$ = ast::nodes::TypeExpression(std::move($mt)); }
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
	: statement_function_call[fc]
		{ $$ = ast::nodes::Statement(std::move($fc)); }
	| variable_decl[var_decl]
		{ $$ = ast::nodes::Statement(std::move($var_decl)); }
	;

statement_function_call
	: IDENT[name] LPAREN arguments[args] RPAREN
		{
			$$ = ast::nodes::FunctionCall(
				std::make_unique<ast::nodes::ValueExpr>(ast::nodes::ValueExpr(ast::nodes::ValueSymbol(std::move($name)))),
				std::move($args)
			);
		}
	| IDENT[pkg] DOLLAR IDENT[name] LPAREN arguments[args] RPAREN
		{
			$$ = ast::nodes::FunctionCall(
				std::make_unique<ast::nodes::ValueExpr>(ast::nodes::ValueExpr(ast::nodes::PackageValueSymbol(std::move($name), std::move($pkg)))),
				std::move($args)
			);
		}
	| AT IDENT[pkg] DOLLAR IDENT[name] LPAREN arguments[args] RPAREN
		{
			$$ = ast::nodes::FunctionCall(
				std::make_unique<ast::nodes::ValueExpr>(ast::nodes::ValueExpr(ast::nodes::IntrinsicValueSymbol(std::move($name), std::move($pkg)))),
				std::move($args)
			);
		}
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
	| value_expr[v]
		{
			$$ = std::vector<std::unique_ptr<ast::nodes::ValueExpr>>();
			$$.push_back(std::make_unique<ast::nodes::ValueExpr>(std::move($v)));
		}
	| arguments[args] COMMA value_expr[v]
		{
			$args.push_back(std::make_unique<ast::nodes::ValueExpr>(std::move($v)));
			$$ = std::move($args);
		}
	;

%%

static std::string findLine(const std::string& source, int lineNumber) {
	int currentLine = 1;
	size_t lineStart = 0;

	while (lineStart <= source.size()) {
		size_t lineEnd = source.find('\n', lineStart);
		if (lineEnd == std::string::npos) {
			lineEnd = source.size();
		}

		if (currentLine == lineNumber) {
			return source.substr(lineStart, lineEnd - lineStart);
		}

		if (lineEnd == source.size()) {
			break;
		}

		lineStart = lineEnd + 1;
		++currentLine;
	}

	return std::string();
}

void yy::Parser::error(const location_type& loc, const std::string& msg) {
	std::cerr << sourcePath << ":" << loc.begin.line << ":" << loc.begin.column << ": error: " << msg << "\n";

	const std::string line = findLine(source, loc.begin.line);
	if (line.empty()) {
		return;
	}

	const std::string lineNumber = std::to_string(loc.begin.line);
	std::cerr << lineNumber << " | " << line << "\n";

	std::string caretLine;
	caretLine.reserve(lineNumber.size() + 3 + line.size());
	caretLine.append(lineNumber.size(), ' ');
	caretLine += " | ";
	for (int column = 1; column < loc.begin.column; ++column) {
		caretLine += static_cast<size_t>(column - 1) < line.size() && line[static_cast<size_t>(column - 1)] == '\t' ? '\t' : ' ';
	}

	const int highlightWidth = std::max(1, loc.end.column - loc.begin.column);
	caretLine.append(static_cast<size_t>(highlightWidth), '^');
	std::cerr << caretLine << "\n";
}
