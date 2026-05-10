#pragma once

#include "semantic/metadata.hpp"

#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace intrinsics {

enum class Category {
	Primitive,
	Concept,
	Function,
};

enum class LoweringKind {
	CompilerType,
	CompilerFunction,
	RuntimeFunction,
};

struct IntrinsicInfo {
	std::string fullName;
	Category category;
	LoweringKind loweringKind;
	std::string llvmTypeName;
	std::string runtimeSymbol;
	std::optional<ir::NodeKind> literalNodeKind;
	std::shared_ptr<semantic::ValueSymbol> callableSymbol;

	bool isType() const {
		return category != Category::Function;
	}

	bool isFunction() const {
		return category == Category::Function;
	}
};

class Registry {
public:
	Registry();

	const IntrinsicInfo* find(std::string_view fullName) const;
	const std::unordered_map<std::string, IntrinsicInfo>& all() const;
	const std::vector<std::shared_ptr<semantic::ValueSymbol>>& callableSymbols() const;
	std::string conceptForLiteralNode(const ir::NodeKind& nodeKind) const;

private:
	std::unordered_map<std::string, IntrinsicInfo> entries;
	std::vector<std::shared_ptr<semantic::ValueSymbol>> functionSymbols;

	void registerType(
		std::string fullName,
		Category category,
		std::string llvmTypeName,
		std::optional<ir::NodeKind> literalNodeKind = std::nullopt
	);
	void registerFunction(
		std::string fullName,
		LoweringKind loweringKind,
		std::string returnTypeName,
		std::vector<std::string> parameterTypeNames,
		std::string runtimeSymbol = {}
	);
};

Registry& get();

} // namespace intrinsics
