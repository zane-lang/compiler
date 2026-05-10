#include "compiler/intrinsics.hpp"

#include <utility>

namespace intrinsics {

namespace nk = ir::node_kind;

namespace {

std::shared_ptr<semantic::Type> makeNamedType(const std::string& name) {
	auto symbol = std::make_shared<semantic::TypeSymbol>();
	symbol->name = name;
	return std::make_shared<semantic::Type>(symbol);
}

} // namespace

Registry::Registry() {
	registerType("@Primitives$String", Category::Primitive, "ptr");
	registerType("@Concepts$StringLiteral", Category::Concept, "ptr", nk::string_literal{});
	registerType("@Concepts$Text", Category::Concept, "ptr");
	registerType("@Concepts$Number", Category::Concept, "i64", nk::number_literal{});

	registerFunction(
		"@Compiler$stringFromStringLiteral",
		LoweringKind::CompilerFunction,
		"@Primitives$String",
		{"@Concepts$StringLiteral"}
	);
	registerFunction(
		"@Functions$printLine",
		LoweringKind::RuntimeFunction,
		"Void",
		{"@Primitives$String"},
		"zane_printLine"
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
	entries.emplace(
		fullName,
		IntrinsicInfo{
			std::move(fullName),
			category,
			LoweringKind::CompilerType,
			std::move(llvmTypeName),
			{},
			std::move(literalNodeKind),
			nullptr,
		}
	);
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
	entries.emplace(
		fullName,
		IntrinsicInfo{
			std::move(fullName),
			Category::Function,
			loweringKind,
			{},
			std::move(runtimeSymbol),
			{},
			callableSymbol,
		}
	);
}

Registry& get() {
	static Registry registry;
	return registry;
}

} // namespace intrinsics
