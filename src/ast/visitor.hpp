#pragma once

#include "ast/ast_helpers.hpp"
#include "ast/symbol_collector.hpp"
#include "ir/node.hpp"

#include <memory>
#include <string>

class Visitor {
	std::shared_ptr<ir::Node> program;
	[[maybe_unused]] SymbolCollector& symbolCollector;
	bool hasPackageDecl = false;

public:
	explicit Visitor(SymbolCollector& collector)
		: program(std::make_shared<ir::Node>("program")),
		  symbolCollector(collector) {}

	void buildTree(const zane::Node* root) {
		if (root == nullptr || root->kind != "program") {
			return;
		}

		for (const auto* child : root->children) {
			if (child == nullptr) {
				continue;
			}

			if (child->kind == "package_decl") {
				if (hasPackageDecl) {
					continue;
				}
				hasPackageDecl = true;
			}

			if (auto cloned = ast::cloneNode(child)) {
				program->children.push_back(cloned.release());
			}
		}
	}

	std::shared_ptr<ir::Node> getProgram() const {
		return program;
	}
};
