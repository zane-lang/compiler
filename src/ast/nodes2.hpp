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

template <typename T>
std::unique_ptr<T> clonePtr(const std::unique_ptr<T>& ptr) {
	if (ptr == nullptr) {
		return nullptr;
	}

	return std::make_unique<T>(*ptr);
}

template <typename T>
std::vector<std::unique_ptr<T>> clonePtrVector(const std::vector<std::unique_ptr<T>>& items) {
	std::vector<std::unique_ptr<T>> copies;
	copies.reserve(items.size());
	for (const auto& item : items) {
		copies.push_back(clonePtr(item));
	}
	return copies;
}

#define NODE(name, ...)               \
struct name {                       \
	__VA_ARGS__                     \
	name(name&&) = default;         \
	name& operator=(name&&) = default; \
}

NODE(NameType , 
	std::string name;
	std::vector<std::unique_ptr<TypeExpression>> generics;

	NameType(std::string name, std::vector<std::unique_ptr<TypeExpression>> generics)
	: name(std::move(name)), generics(std::move(generics)) {}
	NameType(const NameType& other)
	: name(other.name), generics(clonePtrVector(other.generics)) {}
);

NODE(FunctionType , 
	std::vector<std::unique_ptr<TypeExpression>> paramTypes;
	std::unique_ptr<TypeExpression> returnType;

	FunctionType(std::vector<std::unique_ptr<TypeExpression>> paramTypes, std::unique_ptr<TypeExpression> returnType)
	: paramTypes(std::move(paramTypes)), returnType(std::move(returnType)) {}
	FunctionType(const FunctionType& other)
	: paramTypes(clonePtrVector(other.paramTypes)), returnType(clonePtr(other.returnType)) {}
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
	Scope(const Scope& other)
	: statements(clonePtrVector(other.statements)) {}
);

NODE(Parameter , 
	std::unique_ptr<TypeExpression> type;
	std::string name;

	Parameter(std::unique_ptr<TypeExpression> type, std::string name)
	: type(std::move(type)), name(std::move(name)) {}
	Parameter(const Parameter& other)
	: type(clonePtr(other.type)), name(other.name) {}
);

NODE(FunctionDecl , 
	std::string name;
	std::vector<Parameter> parameters;
	TypeExpression returnType;
	Scope functionBody;
	bool mutating;

	FunctionDecl(std::string name, std::vector<Parameter> parameters, TypeExpression returnType, Scope functionBody, bool mutating)
		: name(std::move(name)),
		parameters(std::move(parameters)),
		returnType(std::move(returnType)),
		functionBody(std::move(functionBody)),
		mutating(mutating) {}
);

/// The only unary operator
NODE(OperatorFlipCall , 
	std::unique_ptr<ValueExpr> value;

	OperatorFlipCall(std::unique_ptr<ValueExpr> value)
	: value(std::move(value)) {}
	OperatorFlipCall(const OperatorFlipCall& other)
	: value(clonePtr(other.value)) {}
);

NODE(OperatorCall , 
	std::string op;
	std::unique_ptr<ValueExpr> left;
	std::unique_ptr<ValueExpr> right;

	OperatorCall(std::string op, std::unique_ptr<ValueExpr> left, std::unique_ptr<ValueExpr> right)
	: op(std::move(op)), left(std::move(left)), right(std::move(right)) {}
	OperatorCall(const OperatorCall& other)
	: op(std::move(other.op)), left(clonePtr(other.left)), right(clonePtr(other.right)) {}
);

NODE(FunctionCall , 
	std::unique_ptr<ValueExpr> callee;
	std::vector<std::unique_ptr<ValueExpr>> arguments;

	FunctionCall(std::unique_ptr<ValueExpr> callee, std::vector<std::unique_ptr<ValueExpr>> arguments)
	: callee(std::move(callee)), arguments(std::move(arguments)) {}
	FunctionCall(const FunctionCall& other)
	: callee(clonePtr(other.callee)), arguments(clonePtrVector(other.arguments)) {}
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
	ParenthizedValue(const ParenthizedValue& other) : data(clonePtr(other.data)) {}
);

NODE(ValueExpr , 
	std::variant<FunctionCall, ParenthizedValue, OperatorCall, OperatorFlipCall, ValueSymbol, PackageValueSymbol, StringLiteral, IntLiteral, FloatLiteral> data;

	template <typename T>
	explicit ValueExpr(T value) : data(std::move(value)) {}
	ValueExpr(const ValueExpr& other) : data(other.data) {}
);

NODE(Statement , 
	std::variant<FunctionCall> data;

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
