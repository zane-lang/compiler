#pragma once

#include "ast/symbol_collector.hpp"
#include "ast/visitor.hpp"
#include "package/parser_context.hpp"
#include "semantic/metadata.hpp"
#include "utils/aliases.hpp"

#include <zane-cpp.hpp>
#include <filesystem>
#include <memory>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace llvm {
	class LLVMContext;
	class Module;
}

struct Package {
	// Compiler-owned collector shared into package/visitor as an explicit non-owning reference.
	zane::ref<SymbolCollector> symbolCollector;
	// Package owns its visitor outright; the visitor in turn borrows the collector.
	std::unique_ptr<Visitor> visitor;
	std::shared_ptr<semantic::PackageInfo> packageInfo;
	std::shared_ptr<ir::Node> irProgram;

	Package() = delete;
	Package(zane::ref<SymbolCollector> symbolCollector);
	Package(const Package&) = delete;
	Package& operator=(const Package&) = delete;
	Package(Package&&) noexcept = default;
	Package& operator=(Package&&) noexcept = default;
	~Package();

	zane::abortable<std::unique_ptr<ParserContext>, std::string> parseFile(const fs::path& path);
	void parse(const std::vector<fs::path>& files);
	void collectSymbols();
	void buildTree(const std::string& packageDir);
	void compile(const std::string& pkgName, const std::vector<fs::path>& files, const std::string& packageDir);
	void writeSymbolsCache(
		std::shared_ptr<semantic::PackageInfo> packageInfo,
		const std::string& packageDir
	);
	std::unique_ptr<llvm::Module> getLlvmModule(
		zane::ref<llvm::LLVMContext> context,
		zane::ref<Package> package,
		zane::ref<Packages> allPackages,
		const std::vector<std::shared_ptr<semantic::PackageInfo>>& externalPackages,
		const std::string& triple);
	std::shared_ptr<semantic::PackageInfo> getPackageInfo() const;
	std::shared_ptr<ir::Node> getIRProgram() const;
	std::string getDebugOutput() const;

private:
	std::vector<std::unique_ptr<ParserContext>> contexts;
	std::vector<fs::path> files;
};
