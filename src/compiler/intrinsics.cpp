#include "compiler/helios_symbols.hpp"
#include "compiler/intrinsics.hpp"
#include "utils/console.hpp"

#include <coda.hpp>
#include <exception>
#include <utility>

namespace intrinsics {

namespace nk = ir::node_kind;

std::shared_ptr<semantic::Type> makeNamedType(const std::string& name) {
	auto symbol = std::make_shared<semantic::TypeSymbol>();
	symbol->name = name;
	return std::make_shared<semantic::Type>(symbol);
}

void reportHeliosSymbolsError(const std::string& message) {
	DEBUG(message);
	std::cerr << message << std::endl;
}

std::optional<ir::NodeKind> literalNodeKindFromHelios(std::string_view nodeName) {
	if (nodeName == "string_literal") {
		return nk::string_literal{};
	}

	if (nodeName == "int_literal") {
		return nk::int_literal{};
	}

	if (nodeName == "float_literal") {
		return nk::float_literal{};
	}

	return std::nullopt;
}

Registry::Registry() {
	loadHeliosSymbols();

	registerFunction(
		"@Compiler$stringFromStringLiteral",
		LoweringKind::CompilerFunction,
		"@Primitives$String",
		{"@Concepts$String"}
	);
}

const IntrinsicInfo* Registry::find(std::string_view fullName) const {
	auto it = entries.find(std::string(fullName));
	return it == entries.end() ? nullptr : &it->second;
}

const std::unordered_map<std::string, IntrinsicInfo>& Registry::all() const {
	return entries;
}

const std::vector<std::shared_ptr<semantic::ValueSymbol>>& Registry::callableSymbols() const {
	return functionSymbols;
}

std::string Registry::conceptForLiteralNode(const ir::NodeKind& nodeKind) const {
	for (const auto& [fullName, info] : entries) {
		(void)fullName;
		if (
			info.category == Category::Concept
			&& info.literalNodeKind.has_value()
			&& info.literalNodeKind.value() == nodeKind
		) {
			return info.fullName;
		}
	}

	return {};
}

void Registry::registerType(
		std::string fullName,
		Category category,
		std::string llvmTypeName,
		std::optional<ir::NodeKind> literalNodeKind) {
	IntrinsicInfo info{
		fullName,
		category,
		LoweringKind::CompilerType,
		std::move(llvmTypeName),
		{},
		std::move(literalNodeKind),
		nullptr,
	};
	entries.emplace(info.fullName, std::move(info));
}

void Registry::registerFunction(
		std::string fullName,
		LoweringKind loweringKind,
		std::string returnTypeName,
		std::vector<std::string> parameterTypeNames,
		std::string runtimeSymbol) {
	auto funcType = std::make_shared<semantic::FuncType>();
	funcType->mod = semantic::FuncMod("open");
	funcType->returnType = makeNamedType(returnTypeName);
	for (const auto& parameterType : parameterTypeNames) {
		funcType->paramTypes.push_back(makeNamedType(parameterType));
	}

	auto callableSymbol = std::make_shared<semantic::ValueSymbol>();
	callableSymbol->name = fullName;
	callableSymbol->type = std::make_shared<semantic::Type>(funcType);

	functionSymbols.push_back(callableSymbol);
	IntrinsicInfo info{
		fullName,
		Category::Function,
		loweringKind,
		{},
		std::move(runtimeSymbol),
		{},
		callableSymbol,
	};
	entries.emplace(info.fullName, std::move(info));
}

void Registry::loadHeliosSymbols() {
	try {
		coda::Doc symbols =
			coda::Doc::parse(std::string(heliosSymbolsSource()), "vendor/helios/symbols.coda");
		auto& root = symbols.root();

		if (root.has("Primitives")) {
			for (const auto& row : root["Primitives"].asTable()) {
				try {
					registerType(
						"@Primitives$" + row["name"],
						Category::Primitive,
						row["type"]
					);
				}
				catch (const std::exception& error) {
					reportHeliosSymbolsError(
						std::string("Skipping malformed Helios primitive entry: ") + error.what()
					);
				}
			}
		}

		if (root.has("Concepts")) {
			for (const auto& row : root["Concepts"].asTable()) {
				try {
					const auto literalNodeKind = literalNodeKindFromHelios(row["node"]);

					registerType(
						"@Concepts$" + row["name"],
						Category::Concept,
						row["type"],
						literalNodeKind
					);
				}
				catch (const std::exception& error) {
					reportHeliosSymbolsError(
						std::string("Skipping malformed Helios concept entry: ") + error.what()
					);
				}
			}
		}

		if (root.has("Functions")) {
			for (const auto& entry : root["Functions"].asArray()) {
				try {
					const auto& function = entry->asBlock();
					if (
						!function.has("name")
						|| !function.has("runtimeSymbol")
						|| !function.has("returnType")
						|| !function.has("parameterTypes")
					) {
						continue;
					}

					std::vector<std::string> parameterTypes;
					for (const auto& parameterType : function["parameterTypes"].asArray()) {
						parameterTypes.push_back(parameterType->asString());
					}

					registerFunction(
						"@Functions$" + function["name"].asString(),
						LoweringKind::RuntimeFunction,
						function["returnType"].asString(),
						std::move(parameterTypes),
						function["runtimeSymbol"].asString()
					);
				}
				catch (const std::exception& error) {
					reportHeliosSymbolsError(
						std::string("Skipping malformed Helios function entry: ") + error.what()
					);
				}
			}
		}
	}
	catch (const coda::ParseError& error) {
		reportHeliosSymbolsError(
			std::string("Failed to parse embedded Helios symbols: ") + error.what()
		);
		return;
	}
	catch (const std::exception& error) {
		reportHeliosSymbolsError(
			std::string("Failed to load embedded Helios symbols: ") + error.what()
		);
		return;
	}
}

Registry& get() {
	static Registry registry;
	return registry;
}

} // namespace intrinsics
