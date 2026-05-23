#pragma once

#include "ast/nodes.hpp"
#include <sstream>
#include <string>
#include <variant>
#include <vector>

namespace ast::evaluators {

struct ToString {
std::string operator()(const nodes::StringLiteral& literal) const {
	return formatNode("StringLiteral \"" + literal.data + "\"", {});
}

std::string operator()(const nodes::ValueSymbol& symbol) const {
	return formatNode("ValueSymbol " + symbol.name, {});
}

std::string operator()(const nodes::FunctionCall& call) const {
	std::vector<std::string> children;
	if (call.callee != nullptr) {
		children.push_back(formatBranch("callee", render(*call.callee)));
	}

	for (std::size_t i = 0; i < call.arguments.size(); ++i) {
		children.push_back(formatBranch("argument[" + std::to_string(i) + "]", render(call.arguments[i])));
	}

	return formatNode("FunctionCall", children);
}

std::string operator()(const nodes::NameType& type) const {
	std::vector<std::string> children;
	for (std::size_t i = 0; i < type.generics.size(); ++i) {
		children.push_back(formatBranch("generic[" + std::to_string(i) + "]", render(type.generics[i])));
	}

	return formatNode("NameType " + type.name, children);
}

std::string operator()(const nodes::FunctionType& type) const {
	std::vector<std::string> children;
	for (std::size_t i = 0; i < type.paramTypes.size(); ++i) {
		children.push_back(formatBranch("paramType[" + std::to_string(i) + "]", render(type.paramTypes[i])));
	}

	if (type.returnType != nullptr) {
		children.push_back(formatBranch("returnType", render(*type.returnType)));
	}

	return formatNode("FunctionType", children);
}

std::string operator()(const nodes::TypeExpression& expression) const {
	return std::visit(*this, expression.data);
}

std::string operator()(const nodes::Parameter& parameter) const {
	std::vector<std::string> children;
	if (parameter.type != nullptr) {
		children.push_back(formatBranch("type", render(*parameter.type)));
	}

	return formatNode("Parameter " + parameter.name, children);
}

std::string operator()(const nodes::Statement& statement) const {
	return formatNode("Statement", {formatBranch("data", std::visit(*this, statement.data))});
}

std::string operator()(const nodes::Scope& scope) const {
	std::vector<std::string> children;
	for (std::size_t i = 0; i < scope.statements.size(); ++i) {
		if (scope.statements[i] != nullptr) {
			children.push_back(formatBranch("statement[" + std::to_string(i) + "]", render(*scope.statements[i])));
		}
	}

	return formatNode("Scope", children);
}

std::string operator()(const nodes::FunctionDecl& declaration) const {
	std::vector<std::string> children;
	children.push_back(formatLeaf("mutating", declaration.mutating ? "true" : "false"));

	for (std::size_t i = 0; i < declaration.parameters.size(); ++i) {
		children.push_back(formatBranch("parameter[" + std::to_string(i) + "]", render(declaration.parameters[i])));
	}

	children.push_back(formatBranch("returnType", render(declaration.returnType)));
	children.push_back(formatBranch("functionBody", render(declaration.functionBody)));

	return formatNode("FunctionDecl " + declaration.name, children);
}

std::string operator()(const nodes::Declaration& declaration) const {
	return std::visit(*this, declaration);
}

std::string operator()(const nodes::Package& package) const {
	std::vector<std::string> children;
	for (std::size_t i = 0; i < package.declarations.size(); ++i) {
		children.push_back(formatBranch("declaration[" + std::to_string(i) + "]", render(package.declarations[i])));
	}

	return formatNode("Package", children);
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

static std::string formatLeaf(const std::string& label, const std::string& value) {
	return label + ": " + value;
}

static std::string formatBranch(const std::string& label, const std::string& subtree) {
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

static std::string formatNode(const std::string& label, const std::vector<std::string>& children) {
	if (children.empty()) {
		return label;
	}

	std::string result = label;
	for (std::size_t i = 0; i < children.size(); ++i) {
		result += "\n";
		result += i + 1 == children.size() ? "`-- " : "|-- ";
		result += indent(children[i], i + 1 == children.size() ? "    " : "|   ");
	}

	return result;
}

static std::string indent(const std::string& text, const std::string& prefix) {
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

static std::vector<std::string> splitLines(const std::string& text) {
	std::istringstream input(text);
	std::vector<std::string> lines;
	std::string line;

	while (std::getline(input, line)) {
		lines.push_back(line);
	}

	return lines;
}

};

} // namespace evaluators
