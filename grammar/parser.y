%{
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>

#include "ast.hpp"

int yylex(void);
void yyerror(const char* message);

zane::Node* g_root = nullptr;

static zane::Node* takeNode(const char* kind, char* text) {
zane::Node* node = zane::makeNode(kind, text == nullptr ? std::string() : std::string(text));
std::free(text);
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
}

%define parse.error detailed

%union {
char* text;
zane::Node* node;
zane::NodeList* list;
}

%token <text> NAME NUMBER STRING TYPE_PARAM
%token PACKAGE IMPORT CLASS STRUCT REF IMPLICIT THIS MUT IF ELIF ELSE GUARD LOOP FROM TO RETURN ABORT RESOLVE SPAWN INIT AND OR TRUE FALSE
%token ARROW FAT_ARROW QQ EQEQ NEQ LE GE

%type <node> program item package_decl import_decl type_decl class_kind field_decl function_decl return_type opt_abort_annotation opt_mut callable_body block statement symbol_decl expression handler_suffix_opt handler_clause else_clause_opt assignment_stmt if_stmt guard_stmt return_stmt abort_stmt resolve_stmt expression_stmt logic_expression comparison_expression additive_expression multiplicative_expression unary_expression postfix_expression primary_expression value_name named_type type_expr field_arg field_args_opt arg_list_opt
%type <list> item_list field_decl_list_opt parameter_list_opt parameter_list_opt_nonempty statement_list arg_list field_arg_list elif_clause_list_opt

%destructor { std::free($$); } <text>

%%

program:
item_list {
g_root = zane::makeNode("program");
zane::adoptList(g_root, $1);
$$ = g_root;
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
| function_decl
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
;

function_decl:
return_type value_name '(' parameter_list_opt ')' opt_mut callable_body {
$$ = zane::makeNode("function_decl");
zane::adopt($$, $1);
zane::adopt($$, $2);
zane::adoptList($$, $4);
zane::adopt($$, $6);
zane::adopt($$, $7);
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

parameter_list_opt:
%empty {
$$ = zane::makeList();
}
| parameter_list_opt_nonempty {
$$ = $1;
}
;

parameter_list_opt_nonempty:
NAME type_expr {
$$ = zane::makeList();
zane::Node* param = zane::makeNode("param_decl", $1);
std::free($1);
zane::adopt(param, $2);
zane::push($$, param);
}
| NAME REF type_expr {
$$ = zane::makeList();
zane::Node* param = zane::makeNode("param_decl", $1);
std::free($1);
zane::adopt(param, zane::makeNode("ref"));
zane::adopt(param, $3);
zane::push($$, param);
}
| THIS type_expr {
$$ = zane::makeList();
zane::Node* param = zane::makeNode("param_decl", "this");
zane::adopt(param, $2);
zane::push($$, param);
}
| parameter_list_opt_nonempty ',' NAME type_expr {
zane::Node* param = zane::makeNode("param_decl", $3);
std::free($3);
zane::adopt(param, $4);
zane::push($1, param);
$$ = $1;
}
| parameter_list_opt_nonempty ',' NAME REF type_expr {
zane::Node* param = zane::makeNode("param_decl", $3);
std::free($3);
zane::adopt(param, zane::makeNode("ref"));
zane::adopt(param, $5);
zane::push($1, param);
$$ = $1;
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
NAME type_expr '=' expression {
$$ = zane::makeNode("symbol_decl", $1);
std::free($1);
zane::adopt($$, $2);
zane::adopt($$, $4);
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
GUARD expression block {
$$ = zane::makeNode("guard_stmt");
zane::adopt($$, $2);
zane::adopt($$, $3);
}
;

return_stmt:
RETURN expression {
$$ = zane::makeNode("return_stmt");
zane::adopt($$, $2);
}
;

abort_stmt:
ABORT {
$$ = zane::makeNode("abort_stmt");
}
;

resolve_stmt:
RESOLVE expression {
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
unary_expression {
$$ = $1;
}
| multiplicative_expression '*' unary_expression {
$$ = makeBinary("*", $1, $3);
}
| multiplicative_expression '/' unary_expression {
$$ = makeBinary("/", $1, $3);
}
;

unary_expression:
postfix_expression {
$$ = $1;
}
| '~' unary_expression {
$$ = makeUnary("~", $2);
}
| SPAWN unary_expression {
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
| postfix_expression '(' arg_list_opt ')' {
$$ = zane::makeNode("call_expr");
zane::adopt($$, $1);
zane::adopt($$, $3);
}
| postfix_expression ':' value_name '(' arg_list_opt ')' {
$$ = zane::makeNode("method_call_expr", ":");
zane::adopt($$, $1);
zane::adopt($$, $3);
zane::adopt($$, $5);
}
| postfix_expression '!' value_name '(' arg_list_opt ')' {
$$ = zane::makeNode("method_call_expr", "!");
zane::adopt($$, $1);
zane::adopt($$, $3);
zane::adopt($$, $5);
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
	| value_name '{' field_args_opt '}' {
		$$ = zane::makeNode("field_ctor_expr");
		zane::adopt($$, $1);
		zane::adopt($$, $3);
	}
| '(' expression ')' {
$$ = zane::makeNode("group_expr");
zane::adopt($$, $2);
}
;

field_args_opt:
%empty {
$$ = zane::makeNode("field_args");
}
| field_arg_list {
$$ = zane::makeNode("field_args");
zane::adoptList($$, $1);
}
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

arg_list_opt:
%empty {
$$ = zane::makeNode("args");
}
| arg_list {
$$ = zane::makeNode("args");
zane::adoptList($$, $1);
}
;

arg_list:
expression {
$$ = zane::makeList();
zane::push($$, $1);
}
| arg_list ',' expression {
zane::push($1, $3);
$$ = $1;
}
;

value_name:
NAME {
$$ = takeNode("name", $1);
}
| value_name '$' NAME {
$$ = zane::makeNode("qualified_name");
zane::adopt($$, $1);
zane::adopt($$, takeNode("segment", $3));
}
;

named_type:
NAME {
$$ = takeNode("named_type", $1);
}
| named_type '$' NAME {
$$ = zane::makeNode("qualified_type");
zane::adopt($$, $1);
zane::adopt($$, takeNode("segment", $3));
}
;

type_expr:
named_type {
$$ = $1;
}
| REF named_type {
$$ = zane::makeNode("ref_type");
zane::adopt($$, $2);
}
;

%%

void yyerror(const char* message) {
std::cerr << message << '\n';
}
