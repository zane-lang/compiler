#pragma once

#include "ast/ast_helpers.hpp"
#include "ast/symbol_collector.hpp"
#include "ir/nodes.hpp"

#include <memory>
#include <string>

class Visitor {
	std::shared_ptr<ir::GlobalScope> globalScope;
	[[maybe_unused]] SymbolCollector& symbolCollector;

public:
	explicit Visitor(SymbolCollector& collector)
		: globalScope(std::make_shared<ir::GlobalScope>()),
		  symbolCollector(collector) {}

	void buildTree(const zane::Node* root) {
		if (root == nullptr) {
			return;
		}

		if (globalScope->packageName.empty()) {
			globalScope->packageName = ast::declaredPackageName(root);
		}

		for (const auto* child : root->children) {
			auto lowered = ast::lowerRawAst(child);
			if (lowered) {
				globalScope->body.push_back(lowered);
			}
		}
	}

	std::shared_ptr<ir::GlobalScope> getGlobalScope() const {
		return globalScope;
	}
};
