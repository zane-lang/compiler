#pragma once

#include "ast.hpp"
#include "ir/node.hpp"
#include "ir/nodes.hpp"

#include <memory>
#include <string>
#include <string_view>
#include <vector>

namespace ast {

inline const zane::Node* childAt(const zane::Node* node, std::size_t index) {
	if (node == nullptr || index >= node->children.size()) {
		return nullptr;
	}

	return node->children[index];
}

inline const zane::Node* findChild(const zane::Node* node, std::string_view kind) {
	if (node == nullptr) {
		return nullptr;
	}

	for (const auto* child : node->children) {
		if (child != nullptr && child->kind == kind) {
			return child;
		}
	}

	return nullptr;
}

inline std::vector<const zane::Node*> findChildren(const zane::Node* node, std::string_view kind) {
	std::vector<const zane::Node*> matches;
	if (node == nullptr) {
		return matches;
	}

	for (const auto* child : node->children) {
		if (child != nullptr && child->kind == kind) {
			matches.push_back(child);
		}
	}

	return matches;
}

inline std::string flattenName(const zane::Node* node) {
	if (node == nullptr) {
		return {};
	}

	if (
		node->kind == "name"
		|| node->kind == "segment"
		|| node->kind == "type_name"
		|| node->kind == "operator_name"
		|| node->kind == "type_param"
	) {
		return node->value;
	}

	if (
		node->kind == "qualified_name"
		|| node->kind == "qualified_type"
		|| node->kind == "callable_name"
		|| node->kind == "package_decl"
		|| node->kind == "import_decl"
	) {
		std::string result;
		for (const auto* child : node->children) {
			auto part = flattenName(child);
			if (part.empty()) {
				continue;
			}

			if (!result.empty()) {
				result += "$";
			}
			result += part;
		}
		return result;
	}

	if (node->kind == "named_type") {
		return flattenName(childAt(node, 0));
	}

	if (!node->value.empty()) {
		return node->value;
	}

	if (!node->children.empty()) {
		return flattenName(node->children.front());
	}

	return {};
}

inline std::shared_ptr<ir::Type> makeNamedType(const std::string& name) {
	auto symbol = std::make_shared<ir::TypeSymbol>();
	symbol->name = name.empty() ? "Void" : name;
	return std::make_shared<ir::Type>(symbol);
}

inline std::shared_ptr<ir::Type> lowerTypeExpr(const zane::Node* node) {
	if (node == nullptr) {
		return makeNamedType("Void");
	}

	if (node->kind == "return_type" || node->kind == "abort_type") {
		return lowerTypeExpr(childAt(node, 0));
	}

	if (node->kind == "type_param") {
		return makeNamedType(node->value);
	}

	if (node->kind == "ref_type") {
		auto symbol = std::make_shared<ir::TypeSymbol>();
		symbol->name = "ref";
		if (const auto* inner = childAt(node, 0)) {
			symbol->generics.push_back(lowerTypeExpr(inner));
		}
		return std::make_shared<ir::Type>(symbol);
	}

	if (
		node->kind == "named_type"
		|| node->kind == "qualified_type"
		|| node->kind == "type_name"
	) {
		auto symbol = std::make_shared<ir::TypeSymbol>();
		symbol->name = flattenName(node->kind == "named_type" ? childAt(node, 0) : node);

		if (const auto* genericArgs = findChild(node, "generic_args")) {
			for (const auto* generic : genericArgs->children) {
				symbol->generics.push_back(lowerTypeExpr(generic));
			}
		}

		return std::make_shared<ir::Type>(symbol);
	}

	return makeNamedType(!node->value.empty() ? node->value : node->kind);
}

inline std::shared_ptr<ir::FuncType> lowerCallableType(const zane::Node* declaration) {
	auto type = std::make_shared<ir::FuncType>();
	type->mod = ir::FuncMod("open");
	type->returnType = makeNamedType("Void");

	if (declaration == nullptr) {
		return type;
	}

	if (declaration->kind == "function_decl") {
		type->returnType = lowerTypeExpr(childAt(declaration, 0));
	}
	else if (
		declaration->kind == "constructor_decl"
		|| declaration->kind == "field_constructor_decl"
	) {
		type->returnType = lowerTypeExpr(childAt(declaration, 0));
	}

	for (const auto* child : declaration->children) {
		if (child == nullptr || child->kind != "param_decl") {
			continue;
		}

		const zane::Node* paramType = nullptr;
		for (auto it = child->children.rbegin(); it != child->children.rend(); ++it) {
			const auto* candidate = *it;
			if (
				candidate != nullptr
				&& (
					candidate->kind == "named_type"
					|| candidate->kind == "type_param"
					|| candidate->kind == "ref_type"
				)
			) {
				paramType = candidate;
				break;
			}
		}

		type->paramTypes.push_back(lowerTypeExpr(paramType));
	}

	return type;
}

inline std::string declaredPackageName(const zane::Node* root) {
	if (root == nullptr || root->kind != "program") {
		return {};
	}

	for (const auto* child : root->children) {
		if (child != nullptr && child->kind == "package_decl") {
			return flattenName(child);
		}
	}

	return {};
}

inline std::shared_ptr<ir::RawAstNode> lowerRawAst(const zane::Node* node) {
	if (node == nullptr) {
		return nullptr;
	}

	auto lowered = std::make_shared<ir::RawAstNode>();
	lowered->kind = node->kind;
	lowered->value = node->value;

	for (const auto* child : node->children) {
		auto loweredChild = lowerRawAst(child);
		if (loweredChild) {
			lowered->children.push_back(loweredChild);
		}
	}

	return lowered;
}

} // namespace ast
