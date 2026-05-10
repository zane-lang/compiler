#pragma once

#include "ast.hpp"
#include "ir/node.hpp"
#include "semantic/metadata.hpp"

#include <memory>
#include <string>
#include <string_view>
#include <vector>

namespace ast {

namespace nk = ir::node_kind;

inline const zane::Node* childAt(const zane::Node* node, std::size_t index) {
	if (node == nullptr || index >= node->children.size()) {
		return nullptr;
	}

	return node->children[index];
}

inline std::string childValue(const zane::Node* node, std::size_t index) {
	const auto* child = childAt(node, index);
	return child != nullptr ? child->value : std::string();
}

inline const zane::Node* findChild(const zane::Node* node, const ir::NodeKind& kind) {
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

inline std::vector<const zane::Node*> findChildren(
		const zane::Node* node,
		const ir::NodeKind& kind) {
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

	if (node->kind.is<nk::name, nk::segment, nk::type_name, nk::operator_name, nk::type_param>()) {
		return node->value;
	}

	if (node->kind.is<nk::intrinsic_name, nk::intrinsic_type>()) {
		std::string namespaceName = childValue(node, 0);
		std::string name = childValue(node, 1);
		if (!namespaceName.empty() && !name.empty()) {
			return "@" + namespaceName + "$" + name;
		}
		return {};
	}

	if (
		node->kind.is<
			nk::qualified_name,
			nk::qualified_type,
			nk::callable_name,
			nk::package_decl,
			nk::import_decl
		>()
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

	if (node->kind.is<nk::named_type>()) {
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

inline std::shared_ptr<semantic::Type> makeNamedType(const std::string& name) {
	auto symbol = std::make_shared<semantic::TypeSymbol>();
	symbol->name = name.empty() ? "Void" : name;
	return std::make_shared<semantic::Type>(symbol);
}

inline std::shared_ptr<semantic::Type> lowerTypeExpr(const zane::Node* node) {
	if (node == nullptr) {
		return makeNamedType("Void");
	}

	if (node->kind.is<nk::return_type, nk::abort_type>()) {
		return lowerTypeExpr(childAt(node, 0));
	}

	if (node->kind.is<nk::type_param>()) {
		return makeNamedType(node->value);
	}

	if (node->kind.is<nk::ref_type>()) {
		auto symbol = std::make_shared<semantic::TypeSymbol>();
		symbol->name = "ref";
		if (const auto* inner = childAt(node, 0)) {
			symbol->generics.push_back(lowerTypeExpr(inner));
		}
		return std::make_shared<semantic::Type>(symbol);
	}

	if (node->kind.is<nk::intrinsic_type>()) {
		auto symbol = std::make_shared<semantic::TypeSymbol>();
		symbol->name = flattenName(node);
		return std::make_shared<semantic::Type>(symbol);
	}

	if (node->kind.is<nk::named_type, nk::qualified_type, nk::type_name>()) {
		auto symbol = std::make_shared<semantic::TypeSymbol>();
		symbol->name = flattenName(node->kind.is<nk::named_type>() ? childAt(node, 0) : node);

		if (const auto* genericArgs = findChild(node, nk::generic_args{})) {
			for (const auto* generic : genericArgs->children) {
				symbol->generics.push_back(lowerTypeExpr(generic));
			}
		}

		return std::make_shared<semantic::Type>(symbol);
	}

	return makeNamedType(
		!node->value.empty() ? node->value : std::string(ir::nodeKindName(node->kind)));
}

inline std::shared_ptr<semantic::FuncType> lowerCallableType(const zane::Node* declaration) {
	auto type = std::make_shared<semantic::FuncType>();
	type->mod = semantic::FuncMod("open");
	type->returnType = makeNamedType("Void");

	if (declaration == nullptr) {
		return type;
	}

	if (declaration->kind.is<nk::function_decl>()) {
		type->returnType = lowerTypeExpr(childAt(declaration, 0));
	}
	else if (declaration->kind.is<nk::constructor_decl, nk::field_constructor_decl>()) {
		type->returnType = lowerTypeExpr(childAt(declaration, 0));
	}

	for (const auto* child : declaration->children) {
		if (child == nullptr || !child->kind.is<nk::param_decl>()) {
			continue;
		}

		const zane::Node* paramType = nullptr;
		bool isRef = false;
		for (const auto* candidate : child->children) {
			if (candidate == nullptr) {
				continue;
			}

			if (candidate->kind.is<nk::ref>()) {
				isRef = true;
			}
			else if (candidate->kind.is<nk::named_type, nk::type_param, nk::ref_type>()) {
				paramType = candidate;
			}
		}

		auto loweredParamType = lowerTypeExpr(paramType);
		if (isRef && paramType != nullptr && !paramType->kind.is<nk::ref_type>()) {
			auto symbol = std::make_shared<semantic::TypeSymbol>();
			symbol->name = "ref";
			symbol->generics.push_back(loweredParamType);
			loweredParamType = std::make_shared<semantic::Type>(symbol);
		}

		type->paramTypes.push_back(loweredParamType);
	}

	return type;
}

inline std::string declaredPackageName(const zane::Node* root) {
	if (root == nullptr || !root->kind.is<nk::program>()) {
		return {};
	}

	for (const auto* child : root->children) {
		if (child != nullptr && child->kind.is<nk::package_decl>()) {
			return flattenName(child);
		}
	}

	return {};
}

inline std::unique_ptr<zane::Node> cloneNode(const zane::Node* node) {
	if (node == nullptr) {
		return nullptr;
	}

	auto clone = std::make_unique<zane::Node>(node->kind, node->value);
	for (const auto* child : node->children) {
		if (auto clonedChild = cloneNode(child)) {
			auto* rawChild = clonedChild.release();
			try {
				clone->children.push_back(rawChild);
			} catch (...) {
				delete rawChild;
				throw;
			}
		}
	}
	return clone;
}

inline std::shared_ptr<semantic::ValueSymbol> makeCallableSymbol(
		const zane::Node* node,
		const std::string& packageName) {
	if (node == nullptr) {
		return nullptr;
	}

	auto symbol = std::make_shared<semantic::ValueSymbol>();
	auto callableType = lowerCallableType(node);
	if (!packageName.empty()) {
		symbol->packageName = packageName;
	}
	symbol->type = std::make_shared<semantic::Type>(callableType);

	if (node->kind.is<nk::function_decl>()) {
		symbol->name = flattenName(childAt(node, 1));
	}
	else if (node->kind.is<nk::constructor_decl, nk::field_constructor_decl>()) {
		symbol->name = flattenName(childAt(node, 0));
	}

	if (symbol->name.empty()) {
		return nullptr;
	}

	return symbol;
}

} // namespace ast
