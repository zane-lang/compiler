#pragma once

#include "ast/nodes.hpp"
#include "treegraph/.hpp"
#include <string>
#include <variant>

namespace ast::evaluators {

struct ToGraph {

	treegraph::Node operator()(const nodes::IntLiteral& literal) const {
		return treegraph::Node("\"" + literal.data + "\"");
	}

	treegraph::Node operator()(const nodes::FloatLiteral& literal) const {
		return treegraph::Node("\"" + literal.data + "\"");
	}

	treegraph::Node operator()(const nodes::StringLiteral& literal) const {
		return treegraph::Node("\"" + literal.data + "\"");
	}

	treegraph::Node operator()(const nodes::IntrinsicValueSymbol& symbol) const {
		return treegraph::Node("@" + symbol.package + "$" + symbol.name);
	}

	treegraph::Node operator()(const nodes::PackageValueSymbol& symbol) const {
		return treegraph::Node(symbol.package + "$" + symbol.name);
	}

	treegraph::Node operator()(const nodes::ValueSymbol& symbol) const {
		return treegraph::Node(symbol.name);
	}

	treegraph::Node operator()(const nodes::OperatorFlipCall& call) const {
		treegraph::Table table;
		if (call.value != nullptr)
			table.insert("Value", treegraph::ptr((*this)(*call.value)));
		return treegraph::Node(std::move(table));
	}

	treegraph::Node operator()(const nodes::OperatorCall& call) const {
		treegraph::Table table;
		table.insert("Operator", treegraph::string(call.op));
		if (call.left != nullptr)
			table.insert("Left", treegraph::ptr((*this)(*call.left)));
		if (call.right != nullptr)
			table.insert("Right", treegraph::ptr((*this)(*call.right)));
		return treegraph::Node(std::move(table));
	}

	treegraph::Node operator()(const nodes::FunctionCall& call) const {
		treegraph::Table table;
		if (call.callee != nullptr)
			table.insert("Callee", treegraph::ptr((*this)(*call.callee)));
		treegraph::List arguments;
		for (const auto& argument : call.arguments)
			if (argument != nullptr)
				arguments.push({}, treegraph::ptr((*this)(*argument)));
		if (!arguments.children.empty())
			table.insert("Arguments", treegraph::list(std::move(arguments)));
		return treegraph::Node(std::move(table));
	}

	treegraph::Node operator()(const nodes::NameType& type) const {
		treegraph::Table table;
		table.insert("Name", treegraph::string(type.name));
		treegraph::List generics;
		for (const auto& generic : type.generics)
			if (generic != nullptr)
				generics.push({}, treegraph::ptr((*this)(*generic)));
		if (!generics.children.empty())
			table.insert("Generics", treegraph::list(std::move(generics)));
		return treegraph::Node(std::move(table));
	}

	treegraph::Node operator()(const nodes::FunctionType& type) const {
		treegraph::Table table;
		treegraph::List parameters;
		for (const auto& parameter : type.parameters)
			if (parameter != nullptr)
				parameters.push({}, treegraph::ptr(std::visit(*this, parameter->data)));
		if (!parameters.children.empty())
			table.insert("Parameters", treegraph::list(std::move(parameters)));
		if (type.returnType != nullptr)
			table.insert("ReturnType", treegraph::ptr((*this)(*type.returnType)));
		return treegraph::Node(std::move(table));
	}

	treegraph::Node operator()(const nodes::MethodType& type) const {
		treegraph::Table table;
		treegraph::List parameters;
		for (const auto& parameter : type.parameters)
			if (parameter != nullptr)
				parameters.push({}, treegraph::ptr(std::visit(*this, parameter->data)));
		if (!parameters.children.empty())
			table.insert("Parameters", treegraph::list(std::move(parameters)));
		if (type.returnType != nullptr)
			table.insert("ReturnType", treegraph::ptr((*this)(*type.returnType)));
		table.insert("IsMutating", treegraph::string(type.isMutating ? "true" : "false"));
		return treegraph::Node(std::move(table));
	}

	treegraph::Node operator()(const nodes::TypeExpression& expression) const {
		treegraph::Table table;
		table.insert("ArrowBody", treegraph::ptr(std::visit(*this, expression.data)));
		return treegraph::Node(std::move(table));
	}

	treegraph::Node operator()(const nodes::Parameter& parameter) const {
		treegraph::Table table;
		table.insert("Name", treegraph::string(parameter.name));
		if (parameter.type != nullptr)
			table.insert("Type", treegraph::ptr((*this)(*parameter.type)));
		return treegraph::Node(std::move(table));
	}

	treegraph::Node operator()(const nodes::Statement& statement) const {
		return std::visit(*this, statement.data);
	}

	treegraph::Node operator()(const nodes::Scope& scope) const {
		treegraph::Table table;
		treegraph::List statements;
		for (const auto& statement : scope.statements)
			if (statement != nullptr)
				statements.push({}, treegraph::ptr((*this)(*statement)));
		if (!statements.children.empty())
			table.insert("Statements", treegraph::list(std::move(statements)));
		return treegraph::Node(std::move(table));
	}

	treegraph::Node operator()(const nodes::VariableDecl& declaration) const {
		treegraph::Table table;
		table.insert("Name", treegraph::string(declaration.name));
		table.insert("Type", treegraph::ptr((*this)(declaration.type)));
		table.insert("Value", treegraph::ptr((*this)(*declaration.value)));
		return treegraph::Node(std::move(table));
	}

	treegraph::Node operator()(const nodes::ArrowBody& body) const {
		return (*this)(*body.returnValue);
	}

	treegraph::Node operator()(const nodes::FunctionDecl& declaration) const {
		treegraph::Table table;
		table.insert("Name", treegraph::string(declaration.name));
		treegraph::List parameters;
		for (const auto& parameter : declaration.parameters)
			parameters.push({}, treegraph::ptr((*this)(parameter)));
		if (!parameters.children.empty())
			table.insert("Parameters", treegraph::list(std::move(parameters)));
		table.insert("ReturnType", treegraph::ptr((*this)(declaration.returnType)));
		table.insert("FunctionBody", treegraph::ptr(std::visit(*this, declaration.functionBody)));
		return treegraph::Node{std::move(table)};
	}

	treegraph::Node operator()(const nodes::MethodDecl& declaration) const {
		treegraph::Table table;
		table.insert("Name", treegraph::string(declaration.name));
		table.insert("IsMutating", treegraph::string(declaration.isMutating ? "true" : "false"));
		treegraph::List parameters;
		for (const auto& parameter : declaration.parameters)
			parameters.push({}, treegraph::ptr((*this)(parameter)));
		if (!parameters.children.empty())
			table.insert("Parameters", treegraph::list(std::move(parameters)));
		table.insert("ReturnType", treegraph::ptr((*this)(declaration.returnType)));
		table.insert("FunctionBody", treegraph::ptr(std::visit(*this, declaration.functionBody)));
		return treegraph::Node{std::move(table)};
	}

	treegraph::Node operator()(const nodes::Declaration& declaration) const {
		return std::visit(*this, declaration);
	}

	treegraph::Node operator()(const nodes::Package& package) const {
		treegraph::Table table;
		treegraph::List declarations;
		for (const auto& declaration : package.declarations)
			declarations.push({}, treegraph::ptr((*this)(declaration)));
		if (!declarations.children.empty())
			table.insert("Declarations", treegraph::list(std::move(declarations)));
		return treegraph::Node{std::move(table)};
	}

	treegraph::Node operator()(const nodes::ParenthizedValue& expression) const {
		return (*this)(*expression.data);
	}

	treegraph::Node operator()(const nodes::ValueExpr& expression) const {
		return std::visit(*this, expression.data);
	}
};

} // namespace ast::evaluators
