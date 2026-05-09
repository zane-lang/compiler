#include "package/package.hpp"

#include "ast/symbol_collector.hpp"
#include "ast/visitor.hpp"
#include "package/parser_context.hpp"

Package::Package(zane::ref<SymbolCollector> symbolCollector)
	: symbolCollector(symbolCollector),
	  visitor(std::make_unique<Visitor>(*symbolCollector)) {}

Package::~Package() = default;

std::shared_ptr<ir::PackageInfo> Package::getPackageInfo() const {
	return packageInfo;
}

std::shared_ptr<ir::GlobalScope> Package::getIRProgram() const {
	return irProgram;
}

std::string Package::getDebugOutput() const {
	if (!irProgram) {
		return "No IR program available.";
	}

	return irProgram->toString();
}
