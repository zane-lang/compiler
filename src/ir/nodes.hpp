#pragma once

#include "ir/node.hpp"
#include "utils/types.hpp"

#include <map>
#include <memory>
#include <nlohmann/json.hpp>
#include <unordered_map>
#include <vector>
#include <string>
#include <any>
#include <unordered_map>
#include <cereal/types/optional.hpp>
#include <cereal/types/memory.hpp>
#include <cereal/types/vector.hpp>
#include <cereal/types/map.hpp>
#include <cereal/types/unordered_map.hpp>
#include <cereal/types/string.hpp>

namespace ir {

inline constexpr char VERSION_PLACEHOLDER_PREFIX = '!';
// Compilation currently runs one project command per thread; keep the
// active placeholder package isolated to that thread while a command runs.
inline thread_local std::unordered_map<std::string, std::string> packageNameOverrides;

inline void setVersionPlaceholderPackage(const std::string& packageName) {
	packageNameOverrides[packageName] =
		std::string{VERSION_PLACEHOLDER_PREFIX} + packageName;
}

inline void setVersionedPackageName(
		const std::string& packageName,
		const std::string& versionTag) {
	packageNameOverrides[packageName] = versionTag + packageName;
}

inline void clearVersionPlaceholderPackage() {
	packageNameOverrides.clear();
}

inline std::string getMangledPackageName(const std::string& packageName) {
	auto it = packageNameOverrides.find(packageName);
	if (it != packageNameOverrides.end()) {
		return it->second;
	}

	return packageName;
}

struct ValueSymbol : public IRNode {
	std::optional<std::string> packageName;
	std::string name;
	std::shared_ptr<ir::Type> type;

	std::any accept(IRVisitor* visitor) override;
	std::string getNodeName() const override;
	std::string getMangledName() const;

	template<typename Archive>
	void serialize(Archive& ar) {
		ar(packageName, name, type);
	}
};

struct TypeSymbol : public IRNode {
	std::optional<std::string> packageName;
	std::vector<std::shared_ptr<Type>> generics;
	std::string name;

	std::any accept(IRVisitor* visitor) override;
	std::string getNodeName() const override;
	std::string getMangledName() const;

	template<typename Archive>
	void serialize(Archive& ar) {
		ar(packageName, name, generics);
	}
};

struct PackageInfo {
	std::string packageName;
	std::vector<std::string> importedPackages;
	std::map<std::string, std::shared_ptr<ValueSymbol>> symbols;

	template<typename Archive>
	void serialize(Archive& ar) {
		ar(packageName, importedPackages, symbols);
	}
};

struct FuncMod {
	enum Value {
		Open,
		Strict,
		Pure
	};

	FuncMod() = default;
	FuncMod(Value mod) : value(mod) { }
	FuncMod(const std::string& mod) : value(getByString(mod)) { }

	Value getByString(const std::string& mod) const {
		return stringToEnum.at(mod);
	}

	std::string getString() const {
		return enumToString.at(value);
	}

	template<typename Archive>
	void serialize(Archive& ar) {
		ar(value);
	}

private:
	static inline const std::map<std::string, Value> stringToEnum = {
		{ "open", Open },
		{ "strict", Strict },
		{ "pure", Pure },
	};

	static inline const std::map<Value, std::string> enumToString = {
		{ Open, "open" },
		{ Strict, "strict" },
		{ Pure, "pure" },
	};

	Value value;
};

struct FuncType : public IRNode {
	std::vector<std::shared_ptr<Type>> paramTypes;
	std::shared_ptr<Type> returnType;
	FuncMod mod;

	std::any accept(IRVisitor* visitor) override;
	std::string getParamString() const;
	std::string getNodeName() const override;
	std::string getMangledName() const;
	bool operator==(const FuncType& other) const;

	template<typename Archive>
	void serialize(Archive& ar) {
		ar(paramTypes, returnType, mod);
	}
};

struct Type : public IRNode {
	WrappingVariant<std::shared_ptr, TypeSymbol, FuncType> value;

	Type() = default;
	Type(std::shared_ptr<TypeSymbol> typeSymbol) {
		value = { typeSymbol };
	}

	Type(std::shared_ptr<FuncType> funcType) {
		value = { funcType };
	}

	std::any accept(IRVisitor* visitor) override;
	std::string getMangledName() const;
	std::string getNodeName() const override;

	template<typename Archive>
	void serialize(Archive& ar) {
		ar(value);
	}
};

} // namespace ir

// Register polymorphic types with cereal
#include <cereal/types/polymorphic.hpp>
#include <cereal/types/base_class.hpp>

CEREAL_REGISTER_TYPE(ir::ValueSymbol)
CEREAL_REGISTER_TYPE(ir::TypeSymbol)
CEREAL_REGISTER_TYPE(ir::Type)
CEREAL_REGISTER_TYPE(ir::FuncType)

// Register inheritance relationships
CEREAL_REGISTER_POLYMORPHIC_RELATION(ir::IRNode, ir::ValueSymbol)
CEREAL_REGISTER_POLYMORPHIC_RELATION(ir::IRNode, ir::TypeSymbol)
CEREAL_REGISTER_POLYMORPHIC_RELATION(ir::IRNode, ir::Type)
CEREAL_REGISTER_POLYMORPHIC_RELATION(ir::IRNode, ir::FuncType)
