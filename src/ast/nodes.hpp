#pragma once
#include <memory>
#include <string>
#include <utility>
#include <variant>
#include <vector>

namespace ast::nodes {

struct Statement;

struct TypeExpression;

struct NameType {
	std::string name;
	std::vector<TypeExpression> generics;
};

struct FunctionType {
	std::vector<TypeExpression> paramTypes;
	std::unique_ptr<TypeExpression> returnType;
};

struct TypeExpression {
	std::variant<NameType, FunctionType> data;
};

struct Scope {
	std::vector<std::unique_ptr<Statement>> statements;
};

struct Parameter {
	std::unique_ptr<TypeExpression> type;
	std::string name;
};

struct FunctionDecl {
	std::string name;
	std::vector<Parameter> parameters;
	TypeExpression returnType;
	Scope functionBody;
	bool mutating;
};



// values
struct ValueExpr;

struct FunctionCall {
	std::unique_ptr<ValueExpr> callee;	
	std::vector<ValueExpr> arguments;
};

/// does not include quotes
struct StringLiteral {
	std::string data;
};

struct ValueSymbol {
	std::string name;
};

struct ValueExpr {
	/// decided not to distinguish between callable and objects, since not verifyable at parse time
	std::variant<FunctionCall, ValueSymbol, StringLiteral> data;
};
// end values

struct Statement {
	std::variant<FunctionCall> data;
};

using Declaration = std::variant<FunctionDecl>;
struct Package {
	std::vector<Declaration> declarations;

	explicit Package() : declarations() {}
};

} // namespace nodes
