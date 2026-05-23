#pragma once
#include <memory>
#include <string>
#include <utility>
#include <variant>
#include <vector>

namespace ast::nodes {

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

	explicit TypeExpression(NameType nameType) : data(std::move(nameType)) {}
	explicit TypeExpression(FunctionType functionType) : data(std::move(functionType)) {}
};

struct FunctionDecl {
	std::string name;	
	FunctionType type;
};

using Declaration = FunctionDecl;

struct Package {
	std::vector<Declaration> declarations;

	explicit Package() : declarations() {};
};

} // namespace nodes
