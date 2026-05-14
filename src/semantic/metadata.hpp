#pragma once

#include "utils/types.hpp"

#include <map>
#include <memory>
#include <nlohmann/json.hpp>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>
#include <cereal/types/map.hpp>
#include <cereal/types/memory.hpp>
#include <cereal/types/optional.hpp>
#include <cereal/types/string.hpp>
#include <cereal/types/unordered_map.hpp>
#include <cereal/types/vector.hpp>

namespace semantic {

struct Type;
struct TypeSymbol;
struct FuncType;
struct ValueSymbol;

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

struct ValueSymbol {
	std::optional<std::string> packageName;
	std::string name;
	std::shared_ptr<Type> type;

	std::string getMangledName() const;

	template<typename Archive>
	void serialize(Archive& ar) {
		ar(packageName, name, type);
	}
};

struct TypeSymbol {
	std::optional<std::string> packageName;
	std::vector<std::shared_ptr<Type>> generics;
	std::string name;

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

struct FuncType {
	std::vector<std::shared_ptr<Type>> paramTypes;
	std::shared_ptr<Type> returnType;
	FuncMod mod;

	std::string getParamString() const;
	std::string getMangledName() const;
	bool operator==(const FuncType& other) const;

	template<typename Archive>
	void serialize(Archive& ar) {
		ar(paramTypes, returnType, mod);
	}
};

struct Type {
	WrappingVariant<std::shared_ptr, TypeSymbol, FuncType> value;

	Type() = default;
	Type(std::shared_ptr<TypeSymbol> typeSymbol) {
		value = { typeSymbol };
	}

	Type(std::shared_ptr<FuncType> funcType) {
		value = { funcType };
	}

	std::string getMangledName() const;

	template<typename Archive>
	void serialize(Archive& ar) {
		ar(value);
	}
};

} // namespace semantic

namespace std {
	template<>
	struct hash<semantic::TypeSymbol> {
		size_t operator()(const semantic::TypeSymbol& ts) const noexcept {
			return std::hash<std::string>{}(ts.getMangledName());
		}
	};

	template<>
	struct hash<semantic::ValueSymbol> {
		size_t operator()(const semantic::ValueSymbol& vs) const noexcept {
			return std::hash<std::string>{}(vs.getMangledName());
		}
	};
	
	template<>
	struct hash<semantic::Type> {
		size_t operator()(const semantic::Type& t) const noexcept {
			return std::hash<std::string>{}(t.getMangledName());
		}
	};
}
