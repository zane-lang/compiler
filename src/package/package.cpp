#include "package/package.hpp"

#include "ast/symbol_collector.hpp"
#include "ast/visitor.hpp"
#include "package/parser_context.hpp"

#include <sstream>

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
	if (contexts.empty()) {
		return {};
	}

	if (contexts.size() == 1) {
		return contexts.front()->getAstJson();
	}

	std::ostringstream output;
	for (std::size_t index = 0; index < contexts.size(); ++index) {
		if (index != 0) {
			output << "\n";
		}

		output << contexts[index]->getAstJson();
	}

	return output.str();
}
