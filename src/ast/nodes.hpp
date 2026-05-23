#pragma once
#include <memory>
#include <string>
#include <utility>
#include <variant>
#include <vector>

namespace ast::nodes {

struct Statement;
struct TypeExpression;

template <typename T>
std::unique_ptr<T> clonePtr(const std::unique_ptr<T>& ptr) {
	if (ptr == nullptr) {
		return nullptr;
	}

	return std::make_unique<T>(*ptr);
}

struct NameType {
	std::string name;
	std::vector<TypeExpression> generics;
};

struct FunctionType {
	std::vector<TypeExpression> paramTypes;
	std::unique_ptr<TypeExpression> returnType;

	FunctionType() = default;
	FunctionType(std::vector<TypeExpression> paramTypes, std::unique_ptr<TypeExpression> returnType);
	FunctionType(const FunctionType& other);
	FunctionType& operator=(const FunctionType& other);
	FunctionType(FunctionType&&) noexcept = default;
	FunctionType& operator=(FunctionType&&) noexcept = default;
};

struct TypeExpression {
	std::variant<NameType, FunctionType> data;

	TypeExpression() = default;
	TypeExpression(std::variant<NameType, FunctionType> data) : data(std::move(data)) {}
	TypeExpression(const TypeExpression&) = default;
	TypeExpression& operator=(const TypeExpression&) = default;
	TypeExpression(TypeExpression&&) noexcept = default;
	TypeExpression& operator=(TypeExpression&&) noexcept = default;
};

struct Scope {
	std::vector<std::unique_ptr<Statement>> statements;

	Scope() = default;
	Scope(const Scope& other);
	Scope& operator=(const Scope& other);
	Scope(Scope&&) noexcept = default;
	Scope& operator=(Scope&&) noexcept = default;
};

struct Parameter {
	std::unique_ptr<TypeExpression> type;
	std::string name;

	Parameter() = default;
	Parameter(std::unique_ptr<TypeExpression> type, std::string name)
		: type(std::move(type)), name(std::move(name)) {}
	Parameter(const Parameter& other);
	Parameter& operator=(const Parameter& other);
	Parameter(Parameter&&) noexcept = default;
	Parameter& operator=(Parameter&&) noexcept = default;
};

struct FunctionDecl {
	std::string name;
	std::vector<Parameter> parameters;
	TypeExpression returnType;
	Scope functionBody;
	bool mutating;

	FunctionDecl() = default;
	FunctionDecl(std::string name, std::vector<Parameter> parameters, TypeExpression returnType, Scope functionBody, bool mutating)
		: name(std::move(name)),
		  parameters(std::move(parameters)),
		  returnType(std::move(returnType)),
		  functionBody(std::move(functionBody)),
		  mutating(mutating) {}
	FunctionDecl(const FunctionDecl&) = default;
	FunctionDecl& operator=(const FunctionDecl&) = default;
	FunctionDecl(FunctionDecl&&) noexcept = default;
	FunctionDecl& operator=(FunctionDecl&&) noexcept = default;
};



// values
struct ValueExpr;

struct FunctionCall {
	std::unique_ptr<ValueExpr> callee;	
	std::vector<ValueExpr> arguments;

	FunctionCall() = default;
	FunctionCall(std::unique_ptr<ValueExpr> callee, std::vector<ValueExpr> arguments);
	FunctionCall(const FunctionCall& other);
	FunctionCall& operator=(const FunctionCall& other);
	FunctionCall(FunctionCall&&) noexcept = default;
	FunctionCall& operator=(FunctionCall&&) noexcept = default;
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

	ValueExpr() = default;
	ValueExpr(std::variant<FunctionCall, ValueSymbol, StringLiteral> data) : data(std::move(data)) {}
	ValueExpr(const ValueExpr&) = default;
	ValueExpr& operator=(const ValueExpr&) = default;
	ValueExpr(ValueExpr&&) noexcept = default;
	ValueExpr& operator=(ValueExpr&&) noexcept = default;
};
// end values

struct Statement {
	std::variant<FunctionCall> data;

	Statement() = default;
	Statement(std::variant<FunctionCall> data) : data(std::move(data)) {}
	Statement(const Statement&) = default;
	Statement& operator=(const Statement&) = default;
	Statement(Statement&&) noexcept = default;
	Statement& operator=(Statement&&) noexcept = default;
};

using Declaration = std::variant<FunctionDecl>;
struct Package {
	std::vector<Declaration> declarations;

	explicit Package() : declarations() {}
	Package(std::vector<Declaration> declarations) : declarations(std::move(declarations)) {}
	Package(const Package&) = default;
	Package& operator=(const Package&) = default;
	Package(Package&&) noexcept = default;
	Package& operator=(Package&&) noexcept = default;
};

inline FunctionType::FunctionType(const FunctionType& other)
	: paramTypes(other.paramTypes), returnType(clonePtr(other.returnType)) {}

inline FunctionType::FunctionType(std::vector<TypeExpression> paramTypes, std::unique_ptr<TypeExpression> returnType)
	: paramTypes(std::move(paramTypes)), returnType(std::move(returnType)) {}

inline FunctionType& FunctionType::operator=(const FunctionType& other) {
	if (this == &other) {
		return *this;
	}

	paramTypes = other.paramTypes;
	returnType = clonePtr(other.returnType);
	return *this;
}

inline Parameter::Parameter(const Parameter& other)
	: type(clonePtr(other.type)), name(other.name) {}

inline Parameter& Parameter::operator=(const Parameter& other) {
	if (this == &other) {
		return *this;
	}

	type = clonePtr(other.type);
	name = other.name;
	return *this;
}

inline FunctionCall::FunctionCall(const FunctionCall& other)
	: callee(clonePtr(other.callee)), arguments(other.arguments) {}

inline FunctionCall::FunctionCall(std::unique_ptr<ValueExpr> callee, std::vector<ValueExpr> arguments)
	: callee(std::move(callee)), arguments(std::move(arguments)) {}

inline FunctionCall& FunctionCall::operator=(const FunctionCall& other) {
	if (this == &other) {
		return *this;
	}

	callee = clonePtr(other.callee);
	arguments = other.arguments;
	return *this;
}

inline Scope::Scope(const Scope& other) {
	statements.reserve(other.statements.size());
	for (const auto& statement : other.statements) {
		statements.push_back(clonePtr(statement));
	}
}

inline Scope& Scope::operator=(const Scope& other) {
	if (this == &other) {
		return *this;
	}

	statements.clear();
	statements.reserve(other.statements.size());
	for (const auto& statement : other.statements) {
		statements.push_back(clonePtr(statement));
	}
	return *this;
}

} // namespace nodes
