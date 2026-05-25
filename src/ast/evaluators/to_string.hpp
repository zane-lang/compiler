#pragma once

#include "ast/nodes.hpp"
#include <sstream>
#include <string>
#include <variant>
#include <vector>

namespace ast::evaluators {

namespace detail::tree {

inline std::vector<std::string> splitLines(const std::string& text) {
	std::istringstream input(text);
	std::vector<std::string> lines;
	std::string line;

	while (std::getline(input, line)) {
		lines.push_back(line);
	}

	return lines;
}

inline std::string indent(const std::string& text, const std::string& prefix) {
	const std::vector<std::string> lines = splitLines(text);
	if (lines.empty()) {
		return {};
	}

	std::string result = lines.front();
	for (std::size_t i = 1; i < lines.size(); ++i) {
		result += "\n" + prefix + lines[i];
	}

	return result;
}

inline std::string leaf(const std::string& label, const std::string& value) {
	return label + ": " + value;
}

inline std::string branch(const std::string& label, const std::string& subtree) {
	const std::vector<std::string> lines = splitLines(subtree);
	if (lines.empty()) {
		return label;
	}

	std::string result = label + ": " + lines.front();
	for (std::size_t i = 1; i < lines.size(); ++i) {
		result += "\n  " + lines[i];
	}

	return result;
}

inline std::string node(const std::string& label, const std::vector<std::string>& children) {
	if (children.empty()) {
		return label;
	}

	std::string result = label;
	for (std::size_t i = 0; i < children.size(); ++i) {
		result += "\n";
		result += i + 1 == children.size() ? "└── " : "├── ";
		result += indent(children[i], i + 1 == children.size() ? "    " : "│   ");
	}

	return result;
}

} // namespace detail::tree

struct ToString {
std::string operator()(const nodes::StringLiteral& literal) const {
	return detail::tree::node("StringLiteral \"" + literal.data + "\"", {});
}

std::string operator()(const nodes::ValueSymbol& symbol) const {
	return detail::tree::node("ValueSymbol " + symbol.name, {});
}

std::string operator()(const nodes::FunctionCall& call) const {
	std::vector<std::string> children;
	if (call.callee != nullptr) {
		children.push_back(detail::tree::branch("callee", render(*call.callee)));
	}

	for (std::size_t i = 0; i < call.arguments.size(); ++i) {
		if (call.arguments[i] != nullptr) {
			children.push_back(detail::tree::branch("argument[" + std::to_string(i) + "]", render(*call.arguments[i])));
		}
	}

	return detail::tree::node("FunctionCall", children);
}

std::string operator()(const nodes::NameType& type) const {
	std::vector<std::string> children;
	for (std::size_t i = 0; i < type.generics.size(); ++i) {
		if (type.generics[i] != nullptr) {
			children.push_back(detail::tree::branch("generic[" + std::to_string(i) + "]", render(*type.generics[i])));
		}
	}

	return detail::tree::node("NameType " + type.name, children);
}

std::string operator()(const nodes::FunctionType& type) const {
	std::vector<std::string> children;
	for (std::size_t i = 0; i < type.paramTypes.size(); ++i) {
		if (type.paramTypes[i] != nullptr) {
			children.push_back(detail::tree::branch("paramType[" + std::to_string(i) + "]", render(*type.paramTypes[i])));
		}
	}

	if (type.returnType != nullptr) {
		children.push_back(detail::tree::branch("returnType", render(*type.returnType)));
	}

	return detail::tree::node("FunctionType", children);
}

std::string operator()(const nodes::TypeExpression& expression) const {
	return std::visit(*this, expression.data);
}

std::string operator()(const nodes::Parameter& parameter) const {
	std::vector<std::string> children;
	if (parameter.type != nullptr) {
		children.push_back(detail::tree::branch("type", render(*parameter.type)));
	}

	return detail::tree::node("Parameter " + parameter.name, children);
}

std::string operator()(const nodes::Statement& statement) const {
	return detail::tree::node("Statement", {detail::tree::branch("data", std::visit(*this, statement.data))});
}

std::string operator()(const nodes::Scope& scope) const {
	std::vector<std::string> children;
	for (std::size_t i = 0; i < scope.statements.size(); ++i) {
		if (scope.statements[i] != nullptr) {
			children.push_back(detail::tree::branch("statement[" + std::to_string(i) + "]", render(*scope.statements[i])));
		}
	}

	return detail::tree::node("Scope", children);
}

std::string operator()(const nodes::FunctionDecl& declaration) const {
	std::vector<std::string> children;
	children.push_back(detail::tree::leaf("mutating", declaration.mutating ? "true" : "false"));

	for (std::size_t i = 0; i < declaration.parameters.size(); ++i) {
		children.push_back(detail::tree::branch("parameter[" + std::to_string(i) + "]", render(declaration.parameters[i])));
	}

	children.push_back(detail::tree::branch("returnType", render(declaration.returnType)));
	children.push_back(detail::tree::branch("functionBody", render(declaration.functionBody)));

	return detail::tree::node("FunctionDecl " + declaration.name, children);
}

std::string operator()(const nodes::Declaration& declaration) const {
	return std::visit(*this, declaration);
}

std::string operator()(const nodes::Package& package) const {
	std::vector<std::string> children;
	for (std::size_t i = 0; i < package.declarations.size(); ++i) {
		children.push_back(detail::tree::branch("declaration[" + std::to_string(i) + "]", render(package.declarations[i])));
	}

	return detail::tree::node("Package", children);
}

std::string operator()(const nodes::ValueExpr& expression) const {
	return std::visit(*this, expression.data);
}

private:
std::string render(const nodes::ValueExpr& expression) const {
	return (*this)(expression);
}

std::string render(const nodes::TypeExpression& expression) const {
	return (*this)(expression);
}

std::string render(const nodes::Parameter& parameter) const {
	return (*this)(parameter);
}

std::string render(const nodes::Statement& statement) const {
	return (*this)(statement);
}

std::string render(const nodes::Scope& scope) const {
	return (*this)(scope);
}

std::string render(const nodes::Declaration& declaration) const {
	return (*this)(declaration);
}
};

} // namespace evaluators
