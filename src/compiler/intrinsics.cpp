#include "compiler/helios_symbols.hpp"
#include "compiler/intrinsics.hpp"

#include <coda.hpp>
#include <utility>

namespace intrinsics {

namespace nk = ir::node_kind;

std::shared_ptr<semantic::Type> makeNamedType(const std::string& name) {
	auto symbol = std::make_shared<semantic::TypeSymbol>();
	symbol->name = name;
	return std::make_shared<semantic::Type>(symbol);
}

Registry::Registry() {
	registerType("@Primitives$String", Category::Primitive, "ptr");
	registerType("@Concepts$StringLiteral", Category::Concept, "ptr", nk::string_literal{});
	registerType("@Concepts$Text", Category::Concept, "ptr");
	registerType("@Concepts$Number", Category::Concept, "i64", nk::number_literal{});
	loadHeliosRuntimeFunctions();

	registerFunction(
		"@Compiler$stringFromStringLiteral",
		LoweringKind::CompilerFunction,
		"@Primitives$String",
		{"@Concepts$StringLiteral"}
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

void Registry::loadHeliosRuntimeFunctions() {
	coda::Doc symbols =
		coda::Doc::parse(std::string(heliosSymbolsSource()), "vendor/helios/symbols.coda");
	auto& root = symbols.root();
	if (!root.has("Functions")) {
		return;
	}

	for (const auto& entry : root["Functions"].asArray()) {
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
}

Registry& get() {
	static Registry registry;
	return registry;
}

} // namespace intrinsics
