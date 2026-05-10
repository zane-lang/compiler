%{
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>

#include "ast.hpp"

static zane::Node* takeNode(const char* kind, char* text) {
zane::Node* node = zane::makeNode(kind, text == nullptr ? std::string() : std::string(text));
	std::free(text);
return node;
}

static zane::Node* wrapList(const char* kind, zane::NodeList* list) {
zane::Node* node = zane::makeNode(kind);
	zane::adoptList(node, list);
return node;
}

static zane::Node* makeBinary(const char* op, zane::Node* left, zane::Node* right) {
zane::Node* node = zane::makeNode("binary_expr", op);
	zane::adopt(node, left);
zane::adopt(node, right);
	return node;
}

static zane::Node* makeUnary(const char* op, zane::Node* operand) {
zane::Node* node = zane::makeNode("unary_expr", op);
	zane::adopt(node, operand);
return node;
}
%}

%code requires {
#include "ast.hpp"
#include "lexer.hpp"
}

%code provides {
int yylex(YYSTYPE* yylval, zane::Lexer* lexer);
void yyerror(zane::Lexer* lexer, zane::Node** root, const char* message);
}

%define api.pure full
%define parse.error detailed
%parse-param { zane::Lexer* lexer }
%parse-param { zane::Node** root }
%lex-param { zane::Lexer* lexer }

%union {
char* text;
zane::Node* node;
	zane::NodeList* list;
}

%token <text> NAME NUMBER STRING TYPE_PARAM
%token PACKAGE IMPORT CLASS STRUCT REF IMPLICIT THIS MUT IF ELIF ELSE GUARD LOOP FROM TO RETURN ABORT RESOLVE SPAWN INIT AND OR TRUE FALSE
%token ARROW FAT_ARROW QQ EQEQ NEQ LE GE

%type <node> program item package_decl import_decl type_decl class_kind field_decl callable_decl function_decl constructor_decl field_constructor_decl callable_name operator_name return_type opt_abort_annotation opt_mut callable_body block parameter_decl ctor_field_entry storage_decl symbol_decl symbol_init_opt call_init field_init if_stmt guard_stmt return_stmt abort_stmt resolve_stmt assignment_stmt expression_stmt statement expression handler_suffix_opt handler_clause else_clause_opt logic_expression comparison_expression additive_expression multiplicative_expression pipe_expression unary_expression postfix_expression primary_expression field_ctor_expr init_expr list_expr field_arg call_arg init_item value_name qualified_value_name named_type qualified_type generic_args_opt type_expr
%type <list> item_list field_decl_list_opt parameter_list_opt parameter_list statement_list ctor_field_entry_list_opt ctor_field_entry_list field_arg_list_opt field_arg_list call_arg_list_opt call_arg_list init_item_list_opt init_item_list elif_clause_list_opt generic_arg_list

%%

program:
	   item_list {
*root = zane::makeNode("program");
zane::adoptList(*root, $1);
	$$ = *root;
}
;

item_list:
		 %empty {
$$ = zane::makeList();
}
| item_list item {
zane::push($1, $2);
	$$ = $1;
}
;

item:
	package_decl
| import_decl
| type_decl
| callable_decl
;

package_decl:
			PACKAGE value_name {
$$ = zane::makeNode("package_decl");
zane::adopt($$, $2);
	}
;

import_decl:
		   IMPORT value_name {
$$ = zane::makeNode("import_decl");
zane::adopt($$, $2);
	}
;

class_kind:
		  CLASS {
$$ = zane::makeNode("class_kind", "class");
}
| STRUCT {
$$ = zane::makeNode("class_kind", "struct");
}
;

type_decl:
		 class_kind named_type '{' field_decl_list_opt '}' {
$$ = zane::makeNode($1->value == "class" ? "class_decl" : "struct_decl");
delete $1;
zane::adopt($$, $2);
	zane::adoptList($$, $4);
}
;

field_decl_list_opt:
				   %empty {
$$ = zane::makeList();
}
| field_decl_list_opt field_decl {
zane::push($1, $2);
	$$ = $1;
}
;

field_decl:
		  NAME type_expr {
$$ = zane::makeNode("field_decl", $1);
std::free($1);
   zane::adopt($$, $2);
}
| NAME REF type_expr {
$$ = zane::makeNode("field_decl", $1);
std::free($1);
   zane::adopt($$, zane::makeNode("ref"));
zane::adopt($$, $3);
	}
;

callable_decl:
			 function_decl
| constructor_decl
| field_constructor_decl
;

function_decl:
			 return_type callable_name '(' parameter_list_opt ')' opt_mut callable_body {
$$ = zane::makeNode("function_decl");
zane::adopt($$, $1);
	zane::adopt($$, $2);
zane::adoptList($$, $4);
	zane::adopt($$, $6);
zane::adopt($$, $7);
	}
;

constructor_decl:
				named_type '(' parameter_list_opt ')' callable_body {
$$ = zane::makeNode("constructor_decl");
zane::adopt($$, $1);
	zane::adoptList($$, $3);
zane::adopt($$, $5);
	}
;

field_constructor_decl:
					  named_type '{' ctor_field_entry_list_opt '}' callable_body {
$$ = zane::makeNode("field_constructor_decl");
zane::adopt($$, $1);
	zane::adoptList($$, $3);
zane::adopt($$, $5);
	}
;

callable_name:
			 value_name {
$$ = zane::makeNode("callable_name");
zane::adopt($$, $1);
	}
| operator_name {
$$ = zane::makeNode("callable_name");
zane::adopt($$, $1);
	}
;

operator_name:
			 '~' {
$$ = zane::makeNode("operator_name", "~");
}
| '*' {
$$ = zane::makeNode("operator_name", "*");
}
| '/' {
$$ = zane::makeNode("operator_name", "/");
}
| '+' {
$$ = zane::makeNode("operator_name", "+");
}
| EQEQ {
$$ = zane::makeNode("operator_name", "==");
}
| '<' {
$$ = zane::makeNode("operator_name", "<");
}
;

return_type:
		   type_expr opt_abort_annotation {
$$ = zane::makeNode("return_type");
zane::adopt($$, $1);
	zane::adopt($$, $2);
}
;

opt_abort_annotation:
					%empty {
$$ = nullptr;
}
| '?' type_expr {
$$ = zane::makeNode("abort_type");
zane::adopt($$, $2);
	}
;

opt_mut:
	   %empty {
$$ = nullptr;
}
| MUT {
$$ = zane::makeNode("mut");
}
;

callable_body:
			 block {
$$ = zane::makeNode("block_body");
zane::adopt($$, $1);
	}
| FAT_ARROW expression {
$$ = zane::makeNode("expr_body");
zane::adopt($$, $2);
	}
;

parameter_list_opt:
				  %empty {
$$ = zane::makeList();
}
| parameter_list
;

parameter_list:
			  parameter_decl {
$$ = zane::makeList();
zane::push($$, $1);
	}
| parameter_list ',' parameter_decl {
zane::push($1, $3);
	$$ = $1;
}
;

parameter_decl:
			  NAME type_expr {
$$ = zane::makeNode("param_decl", $1);
std::free($1);
   zane::adopt($$, $2);
}
| NAME REF type_expr {
$$ = zane::makeNode("param_decl", $1);
std::free($1);
   zane::adopt($$, zane::makeNode("ref"));
zane::adopt($$, $3);
	}
| THIS type_expr {
$$ = zane::makeNode("param_decl", "this");
zane::adopt($$, $2);
	}
;

ctor_field_entry_list_opt:
						 %empty {
$$ = zane::makeList();
}
| ctor_field_entry_list
;

ctor_field_entry_list:
					 ctor_field_entry {
$$ = zane::makeList();
zane::push($$, $1);
	}
| ctor_field_entry_list ',' ctor_field_entry {
zane::push($1, $3);
	$$ = $1;
}
| ctor_field_entry_list ',' {
$$ = $1;
}
;

ctor_field_entry:
				storage_decl {
$$ = zane::makeNode("ctor_field_entry");
zane::adopt($$, $1);
	}
;

storage_decl:
			NAME type_expr symbol_init_opt {
$$ = zane::makeNode("storage_decl", $1);
std::free($1);
   zane::adopt($$, $2);
zane::adopt($$, $3);
	}
| NAME REF type_expr symbol_init_opt {
$$ = zane::makeNode("storage_decl", $1);
std::free($1);
   zane::adopt($$, zane::makeNode("ref"));
zane::adopt($$, $3);
	zane::adopt($$, $4);
}
;

symbol_init_opt:
			   %empty {
$$ = nullptr;
}
| '=' expression {
$$ = zane::makeNode("assign_init");
zane::adopt($$, $2);
	}
| call_init
| field_init
;

call_init:
		 '(' call_arg_list_opt ')' {
$$ = zane::makeNode("call_init");
zane::adoptList($$, $2);
	}
;

field_init:
		  '{' field_arg_list_opt '}' {
$$ = zane::makeNode("field_init");
zane::adoptList($$, $2);
	}
;

block:
	 '{' statement_list '}' {
$$ = zane::makeNode("block");
zane::adoptList($$, $2);
	}
;

statement_list:
			  %empty {
$$ = zane::makeList();
}
| statement_list statement {
zane::push($1, $2);
	$$ = $1;
}
;

statement:
		 symbol_decl
| assignment_stmt
| if_stmt
| guard_stmt
| return_stmt
| abort_stmt
| resolve_stmt
| expression_stmt
;

symbol_decl:
		   storage_decl {
$$ = zane::makeNode("symbol_decl");
zane::adopt($$, $1);
	}
;

assignment_stmt:
			   postfix_expression '=' expression {
$$ = zane::makeNode("assignment_stmt");
zane::adopt($$, $1);
	zane::adopt($$, $3);
}
;

if_stmt:
	   IF expression block elif_clause_list_opt else_clause_opt {
$$ = zane::makeNode("if_stmt");
zane::adopt($$, $2);
	zane::adopt($$, $3);
zane::adoptList($$, $4);
	zane::adopt($$, $5);
}
;

elif_clause_list_opt:
					%empty {
$$ = zane::makeList();
}
| elif_clause_list_opt ELIF expression block {
zane::Node* node = zane::makeNode("elif_clause");
	zane::adopt(node, $3);
zane::adopt(node, $4);
	zane::push($1, node);
$$ = $1;
}
;

else_clause_opt:
			   %empty {
$$ = nullptr;
}
| ELSE block {
$$ = zane::makeNode("else_clause");
zane::adopt($$, $2);
	}
;

guard_stmt:
		  GUARD expression {
$$ = zane::makeNode("guard_stmt");
zane::adopt($$, $2);
	}
| GUARD expression block {
$$ = zane::makeNode("guard_stmt");
zane::adopt($$, $2);
	zane::adopt($$, $3);
}
;

return_stmt:
		   RETURN {
$$ = zane::makeNode("return_stmt");
}
| RETURN expression {
$$ = zane::makeNode("return_stmt");
zane::adopt($$, $2);
	}
;

abort_stmt:
		  ABORT {
$$ = zane::makeNode("abort_stmt");
}
| ABORT expression {
$$ = zane::makeNode("abort_stmt");
zane::adopt($$, $2);
	}
;

resolve_stmt:
			RESOLVE {
$$ = zane::makeNode("resolve_stmt");
}
| RESOLVE expression {
$$ = zane::makeNode("resolve_stmt");
zane::adopt($$, $2);
	}
;

expression_stmt:
			   expression {
$$ = zane::makeNode("expression_stmt");
zane::adopt($$, $1);
	}
;

expression:
		  logic_expression handler_suffix_opt {
if ($2 == nullptr) {
$$ = $1;
} else {
$$ = $2;
zane::adopt($$, $1);
	}
}
;

handler_suffix_opt:
				  %empty {
$$ = nullptr;
}
| '?' handler_clause {
$$ = zane::makeNode("handler_expr");
zane::adopt($$, $2);
	}
| QQ logic_expression {
$$ = zane::makeNode("fallback_expr");
zane::adopt($$, $2);
	}
;

handler_clause:
			  block {
$$ = zane::makeNode("handler_clause");
zane::adopt($$, $1);
	}
| NAME block {
$$ = zane::makeNode("handler_clause", $1);
std::free($1);
   zane::adopt($$, $2);
}
;

logic_expression:
				comparison_expression {
$$ = $1;
}
| logic_expression AND comparison_expression {
$$ = makeBinary("and", $1, $3);
}
| logic_expression OR comparison_expression {
$$ = makeBinary("or", $1, $3);
}
;

comparison_expression:
					 additive_expression {
$$ = $1;
}
| additive_expression EQEQ additive_expression {
$$ = makeBinary("==", $1, $3);
}
| additive_expression NEQ additive_expression {
$$ = makeBinary("~=", $1, $3);
}
| additive_expression '<' additive_expression {
$$ = makeBinary("<", $1, $3);
}
| additive_expression '>' additive_expression {
$$ = makeBinary(">", $1, $3);
}
| additive_expression LE additive_expression {
$$ = makeBinary("<=", $1, $3);
}
| additive_expression GE additive_expression {
$$ = makeBinary(">=", $1, $3);
}
;

additive_expression:
				   multiplicative_expression {
$$ = $1;
}
| additive_expression '+' multiplicative_expression {
$$ = makeBinary("+", $1, $3);
}
| additive_expression '-' multiplicative_expression {
$$ = makeBinary("-", $1, $3);
}
;

multiplicative_expression:
						 pipe_expression {
$$ = $1;
}
| multiplicative_expression '*' pipe_expression {
$$ = makeBinary("*", $1, $3);
}
| multiplicative_expression '/' pipe_expression {
$$ = makeBinary("/", $1, $3);
}
;

pipe_expression:
			   unary_expression {
$$ = $1;
}
| pipe_expression '|' unary_expression {
$$ = makeBinary("|", $1, $3);
}
;

unary_expression:
				postfix_expression {
$$ = $1;
}
| '~' unary_expression {
$$ = makeUnary("~", $2);
}
| SPAWN postfix_expression {
$$ = makeUnary("spawn", $2);
}
;

postfix_expression:
				  primary_expression {
$$ = $1;
}
| postfix_expression '.' NAME {
$$ = zane::makeNode("member_expr", $3);
std::free($3);
   zane::adopt($$, $1);
}
| postfix_expression '[' call_arg_list_opt ']' {
$$ = zane::makeNode("subscript_expr");
zane::adopt($$, $1);
	zane::adoptList($$, $3);
}
| postfix_expression '(' call_arg_list_opt ')' {
$$ = zane::makeNode("call_expr");
zane::adopt($$, $1);
	zane::adoptList($$, $3);
}
| postfix_expression ':' value_name '(' call_arg_list_opt ')' {
$$ = zane::makeNode("method_call_expr", ":");
zane::adopt($$, $1);
	zane::adopt($$, $3);
zane::adoptList($$, $5);
	}
| postfix_expression '!' value_name '(' call_arg_list_opt ')' {
$$ = zane::makeNode("method_call_expr", "!");
zane::adopt($$, $1);
	zane::adopt($$, $3);
zane::adoptList($$, $5);
	}
;

primary_expression:
				  value_name {
$$ = $1;
}
| NUMBER {
$$ = takeNode("number_literal", $1);
}
| STRING {
$$ = takeNode("string_literal", $1);
}
| TRUE {
$$ = zane::makeNode("bool_literal", "true");
}
| FALSE {
$$ = zane::makeNode("bool_literal", "false");
}
| field_ctor_expr
| init_expr
| list_expr
| '(' expression ')' {
$$ = zane::makeNode("group_expr");
zane::adopt($$, $2);
	}
;

field_ctor_expr:
			   value_name '{' field_arg_list_opt '}' {
$$ = zane::makeNode("field_ctor_expr");
zane::adopt($$, $1);
	zane::adoptList($$, $3);
}
;

init_expr:
		 INIT '{' init_item_list_opt '}' {
$$ = zane::makeNode("init_expr");
zane::adoptList($$, $3);
	}
;

list_expr:
		 '[' call_arg_list_opt ']' {
$$ = zane::makeNode("list_expr");
zane::adoptList($$, $2);
	}
;

field_arg_list_opt:
				  %empty {
$$ = zane::makeList();
}
| field_arg_list
;

field_arg_list:
			  field_arg {
$$ = zane::makeList();
zane::push($$, $1);
	}
| field_arg_list ',' field_arg {
zane::push($1, $3);
	$$ = $1;
}
| field_arg_list ',' {
$$ = $1;
}
;

field_arg:
		 NAME ':' expression {
$$ = zane::makeNode("field_arg", $1);
std::free($1);
   zane::adopt($$, $3);
}
| NAME {
$$ = zane::makeNode("field_arg", $1);
std::free($1);
   }
;

call_arg_list_opt:
				 %empty {
$$ = zane::makeList();
}
| call_arg_list
;

call_arg_list:
			 call_arg {
$$ = zane::makeList();
zane::push($$, $1);
	}
| call_arg_list ',' call_arg {
zane::push($1, $3);
	$$ = $1;
}
| call_arg_list ',' {
$$ = $1;
}
;

call_arg:
		expression {
$$ = $1;
}
| NAME ':' expression {
$$ = zane::makeNode("named_arg", $1);
std::free($1);
   zane::adopt($$, $3);
}
;

init_item_list_opt:
				  %empty {
$$ = zane::makeList();
}
| init_item_list
;

init_item_list:
			  init_item {
$$ = zane::makeList();
zane::push($$, $1);
	}
| init_item_list ',' init_item {
zane::push($1, $3);
	$$ = $1;
}
| init_item_list ',' {
$$ = $1;
}
;

init_item:
		 NAME ':' expression {
$$ = zane::makeNode("init_item", $1);
std::free($1);
   zane::adopt($$, $3);
}
| NAME {
$$ = zane::makeNode("init_item", $1);
std::free($1);
   }
| expression {
$$ = zane::makeNode("init_expr_item");
zane::adopt($$, $1);
	}
;

value_name:
		  qualified_value_name {
		$$ = $1;
	}
	| '@' NAME '$' NAME {
		$$ = zane::makeNode("intrinsic_name");
		zane::adopt($$, takeNode("namespace", $2));
		zane::adopt($$, takeNode("name", $4));
	}
;

qualified_value_name:
					NAME {
		$$ = takeNode("name", $1);
	}
	| THIS {
		$$ = zane::makeNode("name", "this");
	}
	| qualified_value_name '$' NAME {
		$$ = zane::makeNode("qualified_name");
		zane::adopt($$, $1);
zane::adopt($$, takeNode("segment", $3));
	}
;

named_type:
		  qualified_type generic_args_opt {
		$$ = zane::makeNode("named_type");
		zane::adopt($$, $1);
		zane::adopt($$, $2);
	}
	| '@' NAME '$' NAME generic_args_opt {
		zane::Node* intrinsic = zane::makeNode("intrinsic_type");
		zane::adopt(intrinsic, takeNode("namespace", $2));
		zane::adopt(intrinsic, takeNode("name", $4));
		$$ = zane::makeNode("named_type");
		zane::adopt($$, intrinsic);
		zane::adopt($$, $5);
	}
;

qualified_type:
			  NAME {
$$ = takeNode("type_name", $1);
}
| qualified_type '$' NAME {
$$ = zane::makeNode("qualified_type");
zane::adopt($$, $1);
	zane::adopt($$, takeNode("segment", $3));
}
;

generic_args_opt:
				%empty {
$$ = nullptr;
}
| '<' generic_arg_list '>' {
$$ = wrapList("generic_args", $2);
}
;

generic_arg_list:
				type_expr {
$$ = zane::makeList();
zane::push($$, $1);
	}
| generic_arg_list ',' type_expr {
zane::push($1, $3);
	$$ = $1;
}
;

type_expr:
		 named_type {
$$ = $1;
}
| TYPE_PARAM {
$$ = takeNode("type_param", $1);
}
| REF named_type {
$$ = zane::makeNode("ref_type");
zane::adopt($$, $2);
	}
;

%%

void yyerror(zane::Lexer* lexer, zane::Node** root, const char* message) {
(void)lexer;
(void)root;
std::cerr << message << '\n';
   }
