#pragma once

#include <memory>
#include <string>
#include <utility>
#include <variant>
#include <vector>

namespace ast::nodes {

struct TypeExpression;
struct ValueExpr;
struct Statement;

#define NODE(name, ...)               \
struct name {                       \
	__VA_ARGS__                     \
	name() = default;               \
	name(name&&) = default;         \
	name& operator=(name&&) = default; \
}

NODE(NameType ,
	std::string name;
	std::vector<std::unique_ptr<TypeExpression>> generics;

	NameType(std::string name, std::vector<std::unique_ptr<TypeExpression>> generics)
	: name(std::move(name)), generics(std::move(generics)) {}
);

NODE(Parameter ,
	std::unique_ptr<TypeExpression> type;
	std::string name;

	Parameter(std::unique_ptr<TypeExpression> type, std::string name)
	: type(std::move(type)), name(std::move(name)) {}
);

NODE(FunctionType ,
	std::vector<Parameter> parameters;
	std::unique_ptr<TypeExpression> returnType;

	FunctionType(std::vector<Parameter> params, std::unique_ptr<TypeExpression> returnType)
	: parameters(std::move(params)), returnType(std::move(returnType)) {}
);

NODE(TypeExpression ,
	std::variant<NameType, FunctionType> data;

	template <typename T>
	explicit TypeExpression(T value) : data(std::move(value)) {}
);

NODE(Scope ,
	std::vector<std::unique_ptr<Statement>> statements;

	explicit Scope(std::vector<std::unique_ptr<Statement>> statements)
	: statements(std::move(statements)) {}
);

NODE(VariableDecl,
	std::string name;
	TypeExpression type;
	std::unique_ptr<ValueExpr> value;

	VariableDecl(
		std::string name,
		TypeExpression type,
		std::unique_ptr<ValueExpr> value
	)
		: name(std::move(name)),
		type(std::move(type)),
		value(std::move(value)) {}
);

NODE(FunctionDecl ,
	std::string name;
	std::vector<Parameter> parameters;
	TypeExpression returnType;
	Scope functionBody;
	bool isMethod;
	bool mutating;

	FunctionDecl(
		std::string name,
		std::vector<Parameter> parameters,
		TypeExpression returnType,
		Scope functionBody,
		bool isMethod,
		bool mutating
	)
		: name(std::move(name)),
		parameters(std::move(parameters)),
		returnType(std::move(returnType)),
		functionBody(std::move(functionBody)),
		isMethod(isMethod),
		mutating(mutating) {}
);

/// The only unary operator
NODE(OperatorFlipCall ,
	std::unique_ptr<ValueExpr> value;

	OperatorFlipCall(std::unique_ptr<ValueExpr> value)
	: value(std::move(value)) {}
);

NODE(OperatorCall ,
	std::string op;
	std::unique_ptr<ValueExpr> left;
	std::unique_ptr<ValueExpr> right;

	OperatorCall(std::string op, std::unique_ptr<ValueExpr> left, std::unique_ptr<ValueExpr> right)
	: op(std::move(op)), left(std::move(left)), right(std::move(right)) {}
);

NODE(FunctionCall ,
	std::unique_ptr<ValueExpr> callee;
	std::vector<std::unique_ptr<ValueExpr>> arguments;

	FunctionCall(std::unique_ptr<ValueExpr> callee, std::vector<std::unique_ptr<ValueExpr>> arguments)
	: callee(std::move(callee)), arguments(std::move(arguments)) {}
);

NODE(StringLiteral ,
	std::string data;

	explicit StringLiteral(std::string data) : data(std::move(data)) {}
);

NODE(IntLiteral ,
	std::string data;

	explicit IntLiteral(std::string data) : data(data) {}
);

NODE(FloatLiteral ,
	std::string data;

	explicit FloatLiteral(std::string data) : data(std::move(data)) {}
);

NODE(IntrinsicValueSymbol,
	std::string name;
	std::string package;

	explicit IntrinsicValueSymbol(std::string name, std::string package) : name(std::move(name)), package(std::move(package)) {}
);

NODE(PackageValueSymbol ,
	std::string name;
	std::string package;

	explicit PackageValueSymbol(std::string name, std::string package) : name(std::move(name)), package(std::move(package)) {}
);

NODE(ValueSymbol ,
	std::string name;

	explicit ValueSymbol(std::string name) : name(std::move(name)) {}
);

NODE(ParenthizedValue ,
	std::unique_ptr<ValueExpr> data;

	explicit ParenthizedValue(std::unique_ptr<ValueExpr> value) : data(std::move(value)) {}
);

NODE(ValueExpr ,
	std::variant<FunctionCall, ParenthizedValue, OperatorCall, OperatorFlipCall, ValueSymbol, PackageValueSymbol, IntrinsicValueSymbol, StringLiteral, IntLiteral, FloatLiteral> data;

	template <typename T>
	explicit ValueExpr(T value) : data(std::move(value)) {}
);

NODE(Statement ,
	std::variant<FunctionCall, VariableDecl> data;

	template <typename T>
	explicit Statement(T value) : data(std::move(value)) {}
);

using Declaration = std::variant<FunctionDecl>;

NODE(Package ,
	std::vector<Declaration> declarations;

	explicit Package(std::vector<Declaration> declarations)
	: declarations(std::move(declarations)) {}
);

#undef NODE

} // namespace ast::nodes
