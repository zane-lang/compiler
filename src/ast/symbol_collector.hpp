#pragma once

#include "ast/ast_helpers.hpp"
#include "ir/node.hpp"
#include "ir/nodes.hpp"
#include "parser/ZaneParser.h"

#include <antlr4-runtime.h>
#include <memory>
#include <stdexcept>
#include <string>
#include <tree/ParseTree.h>
#include <utils/embedded_types.hpp>

using namespace parser;

class SymbolCollector : public CustomZaneVisitor {
	std::map<std::string, std::shared_ptr<ir::PackageInfo>> packages;
	std::shared_ptr<ir::PackageInfo> current;

	void registerSymbol(std::shared_ptr<ir::ValueSymbol> symbol) {
		auto mangled = symbol->getMangledName();
		if (current->symbols.count(mangled)) {
			throw std::runtime_error("Duplicate symbol: " + mangled);
		}
		current->symbols[mangled] = symbol;
	}

	std::any visitVarDef(ZaneParser::VarDefContext *ctx) override {
		auto symbol = std::make_shared<ir::ValueSymbol>();
		symbol->name = ctx->name->getText();
		symbol->packageName = current->packageName;
		symbol->type = get<ir::Type>(ctx->storageType());

		registerSymbol(symbol);
		return 0;
	}

	std::any visitFuncDef(ZaneParser::FuncDefContext *ctx) override {
		auto symbol = std::make_shared<ir::ValueSymbol>();
		symbol->name = ctx->name->getText();
		symbol->packageName = current->packageName;
		symbol->type = std::make_shared<ir::Type>(buildFuncType(
			get<ir::Type>(ctx->returnType),
			ctx->abortClause(),
			ctx->params(),
			ctx->methodMut() != nullptr));

		registerSymbol(symbol);
		return 0;
	}

	std::any visitCtorDef(ZaneParser::CtorDefContext *ctx) override {
		auto symbol = std::make_shared<ir::ValueSymbol>();
		symbol->name = ctx->name->getText();
		symbol->packageName = current->packageName;
		auto returnTypeSymbol = std::make_shared<ir::TypeSymbol>();
		returnTypeSymbol->name = ctx->name->getText();
		returnTypeSymbol->packageName = current->packageName;
		symbol->type = std::make_shared<ir::Type>(buildFuncType(
			std::make_shared<ir::Type>(returnTypeSymbol),
			nullptr,
			ctx->params(),
			false));

		registerSymbol(symbol);
		return 0;
	}

public:
	void collectSymbols(parser::ZaneParser::GlobalScopeContext* globalScopeCtx) {
		if (!globalScopeCtx) {
			throw std::runtime_error("Global scope context is null");
		}

		auto pkgName = globalScopeCtx->pkgDef()->name->getText();
		if (!packages.count(pkgName)) {
			packages[pkgName] = std::make_shared<ir::PackageInfo>();
			packages[pkgName]->packageName = pkgName;
		}
		current = packages[pkgName];

		for (auto import : globalScopeCtx->pkgImport()) {
			current->importedPackages.push_back(import->name->getText());
		}

		for (auto ctx : globalScopeCtx->declaration()) {
			visit(ctx);
		}
	}

	std::shared_ptr<ir::PackageInfo> getPackageInfo() const {
		return current;
	}

	void setCurrentPackage(const std::string& pkgName) {
		auto it = packages.find(pkgName);
		if (it != packages.end()) current = it->second;
	}

	std::shared_ptr<ir::PackageInfo> getPackageInfo(const std::string& pkgName) const {
		auto it = packages.find(pkgName);
		if (it != packages.end()) return it->second;
		return nullptr;
	}

	void registerPackageAlias(
			const std::string& alias,
			std::shared_ptr<ir::PackageInfo> packageInfo) {
		if (!packageInfo) return;
		packages[alias] = std::move(packageInfo);
	}
};
