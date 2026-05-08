#pragma once

#include "ast/ast_helpers.hpp"
#include "ir/nodes.hpp"

#include <map>
#include <memory>
#include <stdexcept>
#include <string>

class SymbolCollector {
	std::map<std::string, std::shared_ptr<ir::PackageInfo>> packages;
	std::shared_ptr<ir::PackageInfo> current;

	void registerSymbol(const std::shared_ptr<ir::ValueSymbol>& symbol) {
		if (!current || !symbol) {
			return;
		}

		auto mangled = symbol->getMangledName();
		if (current->symbols.count(mangled)) {
			throw std::runtime_error("Duplicate symbol: " + mangled);
		}

		current->symbols[mangled] = symbol;
	}

	std::shared_ptr<ir::ValueSymbol> makeCallableSymbol(const zane::Node* declaration) const {
		if (declaration == nullptr || !current) {
			return nullptr;
		}

		auto symbol = std::make_shared<ir::ValueSymbol>();
		symbol->packageName = current->packageName;
		symbol->type = std::make_shared<ir::Type>(ast::lowerCallableType(declaration));

		if (declaration->kind == "function_decl") {
			symbol->name = ast::flattenName(ast::childAt(declaration, 1));
		}
		else if (
			declaration->kind == "constructor_decl"
			|| declaration->kind == "field_constructor_decl"
		) {
			symbol->name = ast::flattenName(ast::childAt(declaration, 0));
		}

		if (symbol->name.empty()) {
			return nullptr;
		}

		return symbol;
	}

public:
	void collectSymbols(const zane::Node* root) {
		if (root == nullptr) {
			throw std::runtime_error("AST root is null");
		}

		auto pkgName = ast::declaredPackageName(root);
		if (pkgName.empty()) {
			throw std::runtime_error("Missing package declaration");
		}

		if (!packages.count(pkgName)) {
			packages[pkgName] = std::make_shared<ir::PackageInfo>();
			packages[pkgName]->packageName = pkgName;
		}
		current = packages[pkgName];

		for (const auto* child : root->children) {
			if (child == nullptr) {
				continue;
			}

			if (child->kind == "import_decl") {
				auto importName = ast::flattenName(child);
				if (!importName.empty()) {
					current->importedPackages.push_back(importName);
				}
				continue;
			}

			if (
				child->kind == "function_decl"
				|| child->kind == "constructor_decl"
				|| child->kind == "field_constructor_decl"
			) {
				registerSymbol(makeCallableSymbol(child));
			}
		}
	}

	std::shared_ptr<ir::PackageInfo> getPackageInfo() const {
		return current;
	}

	void setCurrentPackage(const std::string& pkgName) {
		auto it = packages.find(pkgName);
		if (it != packages.end()) {
			current = it->second;
		}
	}

	std::shared_ptr<ir::PackageInfo> getPackageInfo(const std::string& pkgName) const {
		auto it = packages.find(pkgName);
		if (it != packages.end()) {
			return it->second;
		}

		return nullptr;
	}

	void registerPackageAlias(
			const std::string& alias,
			std::shared_ptr<ir::PackageInfo> packageInfo) {
		if (!packageInfo) {
			return;
		}

		packages[alias] = std::move(packageInfo);
	}
};
