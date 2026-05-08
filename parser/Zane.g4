grammar Zane;

// =====================================================
// ================= Lexer Rules =======================
// =====================================================

// Keywords
PACKAGE: 'package';
IMPORT: 'import';
CLASS: 'class';
STRUCT: 'struct';
REF: 'ref';
MUT: 'mut';
RETURN: 'return';
RESOLVE: 'resolve';
ABORT: 'abort';
INIT: 'init';
SPAWN: 'spawn';
AND: 'and';
OR: 'or';

// Operators
OPERATOR_STAR: '*';
OPERATOR_SLASH: '/';
OPERATOR_PLUS: '+';
OPERATOR_MINUS: '-';
OPERATOR_TILDE: '~';
OPERATOR_LT: '<';
OPERATOR_GT: '>';
OPERATOR_LEQ: '<=';
OPERATOR_GEQ: '>=';
OPERATOR_EQ: '==';
OPERATOR_NEQ: '~=';
OPERATOR_PIPE: '|';
OPERATOR_COLON: ':';
OPERATOR_BANG: '!';
OPERATOR_QUESTION: '?';
OPERATOR_DOUBLE_QUESTION: '??';
OPERATOR_ARROW: '->';
OPERATOR_FAT_ARROW: '=>';

// Delimiters
LPAREN: '(';
RPAREN: ')';
LBRACE: '{';
RBRACE: '}';
LBRACKET: '[';
RBRACKET: ']';
COMMA: ',';
DOT: '.';
DOLLAR: '$';
EQUALS: '=';

// Literals and identifiers
IDENTIFIER: [\p{L}_][\p{L}\p{N}_]*;
STRING: '"' (~["\\\r\n] | '\\' .)* '"';

fragment DIGIT: [0-9];
fragment SIMPLE_NUMBER: DIGIT+('.' DIGIT+)?;
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
    : classDef
    | structDef
    | funcDef
    | varDef
    | constDef
    | subscriptDef
    | operatorDef
    ;

// -----------------------------------------------------
// Package and Imports
// -----------------------------------------------------

pkgDef
    : PACKAGE name=IDENTIFIER
    ;

pkgImport
    : IMPORT name=IDENTIFIER
    ;

// -----------------------------------------------------
// Classes and Structs
// -----------------------------------------------------

classDef
    : CLASS name=IDENTIFIER LBRACE field* RBRACE
    ;

structDef
    : STRUCT name=IDENTIFIER typeParams? LBRACE field* RBRACE
    ;

field
    : (REF)? fieldType=type fieldName=IDENTIFIER
    ;

// -----------------------------------------------------
// Types
// -----------------------------------------------------

typeParams
    : LBRACKET typeParam (COMMA typeParam)* RBRACKET ('<' type (COMMA type)* '>')?
    ;

typeParam
    : IDENTIFIER
    ;

type
    : REF? baseType
    ;

baseType
    : typeSymbol ('<' type (COMMA type)* '>')?          # namedType
    | LPAREN type (COMMA type)* RPAREN OPERATOR_ARROW returnType=type  # functionType
    ;

typeSymbol
    : (package=IDENTIFIER DOLLAR)? name=IDENTIFIER
    ;

valueSymbol
    : (package=IDENTIFIER DOLLAR)? name=IDENTIFIER
    ;

// -----------------------------------------------------
// Functions, Methods, Constructors, and Lambdas
// -----------------------------------------------------

funcDef
    : returnType=type name=IDENTIFIER funcParams? funcMod? funcBody
    | returnType=type OPERATOR_QUESTION abortType=type name=IDENTIFIER funcParams? funcMod? funcBody
    ;

funcParams
    : LPAREN param (COMMA param)* RPAREN
    | LPAREN RPAREN
    ;

param
    : (REF)? paramType=type paramName=IDENTIFIER
    | THIS receiverType=type
    ;

THIS: 'this';

funcMod
    : MUT
    ;

funcBody
    : LBRACE statement* RBRACE
    | OPERATOR_FAT_ARROW value
    ;

// Constructor definition (positional)
constructorDef
    : typeName=typeSymbol funcParams LBRACE statement* RBRACE
    ;

// Field constructor
fieldConstructorDef
    : typeName=typeSymbol LBRACE fieldConstructorParam (COMMA fieldConstructorParam)* RBRACE LBRACE statement* RBRACE
    ;

fieldConstructorParam
    : fieldName=IDENTIFIER fieldType=type
    ;

// Subscript definition
subscriptDef
    : LBRACKET THIS receiverType=type RBRACKET LBRACKET subscriptParam (COMMA subscriptParam)* RBRACKET OPERATOR_FAT_ARROW placeExpr
    ;

subscriptParam
    : paramName=IDENTIFIER paramType=type
    ;

// Operator definition
operatorDef
    : returnType=type operatorSymbol funcParams LBRACE statement* RBRACE
    ;

operatorSymbol
    : OPERATOR_TILDE
    | OPERATOR_STAR
    | OPERATOR_SLASH
    | OPERATOR_PLUS
    | OPERATOR_MINUS
    | OPERATOR_EQ
    | OPERATOR_LT
    ;

// Lambda declaration (assigned to variable)
lambdaDecl
    : funcType varName=IDENTIFIER EQUALS lambdaLiteral
    ;

lambdaLiteral
    : LPAREN param (COMMA param)* RPAREN funcMod? LBRACE statement* RBRACE
    | LPAREN RPAREN funcMod? LBRACE statement* RBRACE
    ;

funcType
    : LPAREN type (COMMA type)* RPAREN funcMod? OPERATOR_ARROW type
    ;

// -----------------------------------------------------
// Variables and Constants
// -----------------------------------------------------

varDef
    : varName=IDENTIFIER (REF)? varType=type EQUALS value
    ;

constDef
    : constName=IDENTIFIER constType=type LPAREN value RPAREN
    ;

// -----------------------------------------------------
// Statements
// -----------------------------------------------------

statement
    : varDef
    | retStat
    | resolveStat
    | abortStat
    | expressionStmt
    ;

expressionStmt
    : value
    ;

retStat
    : RETURN value
    ;

resolveStat
    : RESOLVE value
    | RESOLVE
    ;

abortStat
    : ABORT value
    | ABORT
    ;

// -----------------------------------------------------
// Values and Expressions
// -----------------------------------------------------

value
    : primary (binaryOp primary)*
    ;

binaryOp
    : OPERATOR_STAR
    | OPERATOR_SLASH
    | OPERATOR_PLUS
    | OPERATOR_MINUS
    | OPERATOR_LT
    | OPERATOR_GT
    | OPERATOR_LEQ
    | OPERATOR_GEQ
    | OPERATOR_EQ
    | OPERATOR_NEQ
    | AND
    | OR
    ;

primary
    : atom postfix*
    ;

atom
    : STRING                                    # stringLiteral
    | NUMBER                                    # numberLiteral
    | valueSymbol                               # identifier
    | tuple                                     # tupleLiteral
    | lambdaLiteral                             # lambdaExpr
    | LPAREN value RPAREN                       # parenExpr
    | spawnExpr                                 # spawnExpression
    ;

spawnExpr
    : SPAWN qualifiedCall
    ;

qualifiedCall
    : valueSymbol LPAREN argList? RPAREN
    ;

postfix
    : DOT IDENTIFIER                            # propertyAccess
    | LBRACKET value (COMMA value)* RBRACKET    # subscriptAccess
    | OPERATOR_COLON qualifiedCall              # methodCallReadOnly
    | OPERATOR_BANG qualifiedCall               # methodCallMutating
    | OPERATOR_PIPE LBRACE statement* RBRACE    # pipeBlock
    | OPERATOR_QUESTION IDENTIFIER? LBRACE handlerBody RBRACE  # questionHandler
    | OPERATOR_DOUBLE_QUESTION value            # coalesceOperator
    ;

handlerBody
    : statement* (resolveStat | retStat | abortStat)
    ;

argList
    : value (COMMA value)*
    ;

tuple
    : LPAREN argList? RPAREN
    ;

// Place expressions (for subscripts and ref binding)
placeExpr
    : valueSymbol
    | placeExpr DOT IDENTIFIER
    | placeExpr LBRACKET value (COMMA value)* RBRACKET
    ;

// -----------------------------------------------------
// Init expression (constructor return)
// -----------------------------------------------------

initExpr
    : INIT LBRACE initField (COMMA initField)* RBRACE
    ;

initField
    : fieldName=IDENTIFIER (OPERATOR_COLON value)?
    ;
