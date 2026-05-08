grammar Zane;

// --- Lexer Rules ---
IDENTIFIER: '@'? [\p{L}_] [\p{L}\p{N}_]*;
STRING: '"' (~["\\\r\n] | '\\' .)* '"';

fragment DIGIT: [0-9];
fragment SIMPLE_NUMBER: DIGIT+ ('.' DIGIT+)?;
fragment MANAGED_NUMBER: DIGIT (DIGIT DIGIT?)? ('\'' DIGIT DIGIT DIGIT)* ('.' DIGIT (DIGIT DIGIT?)?)?;
NUMBER: SIMPLE_NUMBER | MANAGED_NUMBER;

WS: [ \t\r\n]+ -> skip;


// =====================================================
// ================= Parser Rules ======================
// =====================================================

globalScope
	: pkgDef pkgImport* declaration* EOF
	;

declaration
	: funcDef
	| ctorDef
	| varDef
	;

// -----------------------------------------------------
// Statements
// -----------------------------------------------------

statement
	: varDef
	| retStat
	| value
	| tuple
	;

pkgDef
	: 'package' name=IDENTIFIER
	;

pkgImport
	: 'import' name=IDENTIFIER
	;

// -----------------------------------------------------
// Types
// -----------------------------------------------------

refModifier
	: 'ref'
	;

abortClause
	: '?' type
	;

funcTypeParam
	: receiver='this' receiverType=type
	| refModifier? type
	;

funcTypeParams
	: funcTypeParam (',' funcTypeParam)*
	;

funcType
	: '(' funcTypeParams? ')' methodMut? '->' returnType=type abortClause?
	;

type
	: refModifier? typePrimary
	;

typePrimary
	: typeSymbol ('<' type (',' type)* '>')?
	| funcType
	;

typeSymbol
	: (package=IDENTIFIER '$')? name=IDENTIFIER
	;

valueSymbol
	: (package=IDENTIFIER '$')? name=IDENTIFIER
	;

// -----------------------------------------------------
// Values
// -----------------------------------------------------

string
	: STRING
	;

number
	: NUMBER
	;

value
	: comparisonExpr
	;

comparisonExpr
	: additiveExpr (comparisonOperator additiveExpr)?
	;

comparisonOperator
	: '<'
	| '>'
	| '<='
	| '>='
	| '=='
	| '~='
	;

additiveExpr
	: multiplicativeExpr (additiveOperator multiplicativeExpr)*
	;

additiveOperator
	: '+'
	| '-'
	;

multiplicativeExpr
	: pipeExpr (multiplicativeOperator pipeExpr)*
	;

multiplicativeOperator
	: '*'
	| '/'
	;

pipeExpr
	: unaryExpr ('|' unaryExpr)*
	;

unaryExpr
	: '~' unaryExpr
	| postfixExpr
	;

postfixExpr
	: atom postfixSuffix*
	;

atom
	: string
	| number
	| valueSymbol
	| tuple
	| lambda
	;

postfixSuffix
	: '(' collection ')'					# funcCallSuffix
	| ':' methodName=valueSymbol '(' collection ')'	# methodCallSuffix
	| '!' methodName=valueSymbol '(' collection ')'	# mutatingMethodCallSuffix
	| '[' collection ']'					# subscriptSuffix
	;

collection
	: (value (',' value)*)?
	;

// -----------------------------------------------------
// Functions
// -----------------------------------------------------

methodMut
	: 'mut'
	;

lambdaParam
	: receiver='this'
	| name=IDENTIFIER
	;

lambdaParams
	: lambdaParam (',' lambdaParam)*
	;

lambda
	: '(' lambdaParams? ')' methodMut? funcBody
	;

param
	: receiver='this' receiverType=type
	| name=IDENTIFIER refModifier? type
	;

params
	: param (',' param)*
	;

operatorName
	: '~'
	| '*'
	| '/'
	| '+'
	| '=='
	| '<'
	;

functionName
	: IDENTIFIER
	| operatorName
	;

funcDef
	: returnType=type abortClause? name=functionName '(' params? ')' methodMut? funcBody
	;

ctorDef
	: name=IDENTIFIER '(' params? ')' funcBody
	;

funcBody
	: arrowFunction
	| scope
	;

arrowFunction
	: '=>' value
	;

scope
	: '{' statement* '}'
	;

// -----------------------------------------------------
// Tuples
// -----------------------------------------------------

tuple
	: '(' collection ')'
	;

// -----------------------------------------------------
// Variables
// -----------------------------------------------------

storageType
	: refModifier? typePrimary
	;

ctorInit
	: '(' collection ')'
	;

varInitializer
	: '=' value
	| ctorInit
	;

varDef
	: name=IDENTIFIER storageType varInitializer?
	;

// -----------------------------------------------------
// Blocks
// -----------------------------------------------------

retStat
	: 'return' value
	;
