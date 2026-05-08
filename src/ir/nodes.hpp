#pragma once

#include "ir/node.hpp"
#include "utils/types.hpp"
#include "parser/ZaneParser.h"

#include <any>
#include <cereal/types/base_class.hpp>
#include <cereal/types/map.hpp>
#include <cereal/types/memory.hpp>
#include <cereal/types/optional.hpp>
#include <cereal/types/polymorphic.hpp>
#include <cereal/types/string.hpp>
#include <cereal/types/unordered_map.hpp>
#include <cereal/types/vector.hpp>
#include <map>
#include <memory>
#include <nlohmann/json.hpp>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

using namespace parser;

namespace ir {

inline constexpr char VERSION_PLACEHOLDER_PREFIX = '!';
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

struct Type;
struct FuncType;

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

struct GlobalScope : public IRNode {
	std::vector<std::shared_ptr<IRNode>> body;
	std::string packageName;

	std::any accept(IRVisitor* visitor) override;
	std::string getNodeName() const override;
	std::string printChildren(const std::string& prefix) const override;

	template<typename Archive>
	void serialize(Archive& ar) {
		ar(packageName, body);
	}
};

struct FuncType : public IRNode {
	std::vector<std::shared_ptr<Type>> paramTypes;
	std::shared_ptr<Type> returnType;
	std::shared_ptr<Type> abortType;
	bool hasReceiver = false;
	bool isMutable = false;

	std::any accept(IRVisitor* visitor) override;
	std::string getParamString() const;
	std::string getNodeName() const override;
	std::string getMangledName() const;
	bool operator==(const FuncType& other) const;

	template<typename Archive>
	void serialize(Archive& ar) {
		ar(paramTypes, returnType, abortType, hasReceiver, isMutable);
	}
};

struct Type : public IRNode {
	WrappingVariant<std::shared_ptr, TypeSymbol, FuncType> value;
	bool isRef = false;

	Type() = default;

	explicit Type(std::shared_ptr<TypeSymbol> typeSymbol) {
		value = { typeSymbol };
	}

	explicit Type(std::shared_ptr<FuncType> funcType) {
		value = { funcType };
	}

	std::any accept(IRVisitor* visitor) override;
	std::string getMangledName() const;
	std::string getNodeName() const override;

	template<typename Archive>
	void serialize(Archive& ar) {
		ar(value, isRef);
	}
};

struct Scope : public IRNode {
	std::weak_ptr<IRNode> parent;
	std::unordered_map<std::string, std::shared_ptr<FuncDef>> functionDefs;
	std::vector<std::shared_ptr<IRNode>> statements;

	std::any accept(IRVisitor* visitor) override;
	std::string getNodeName() const override;
	std::string printChildren(const std::string& prefix) const override;

	template<typename Archive>
	void serialize(Archive& ar) {
		ar(functionDefs, statements);
	}
};

struct ReturnStatement : public IRNode {
	std::shared_ptr<IRNode> value;

	std::any accept(IRVisitor* visitor) override;
	std::string getNodeName() const override;

	template<typename Archive>
	void serialize(Archive& ar) {
		ar(value);
	}
};

struct VarDef : public IRNode {
	std::shared_ptr<ValueSymbol> symbol;
	std::shared_ptr<IRNode> value;

	std::any accept(IRVisitor* visitor) override;
	std::string getNodeName() const override;
	std::string printChildren(const std::string& prefix) const override;

	template<typename Archive>
	void serialize(Archive& ar) {
		ar(symbol, value);
	}
};

struct Lambda : public IRNode {
	std::string name;
	std::vector<std::string> parameters;
	bool hasReceiver = false;
	bool isMutable = false;
	std::shared_ptr<Scope> scope;
	std::shared_ptr<FuncType> type;
	ZaneParser::LambdaContext* ctx = nullptr;

	std::any accept(IRVisitor* visitor) override;
	std::string getNodeName() const override;
	std::string printChildren(const std::string& prefix) const override;

	template<typename Archive>
	void serialize(Archive& ar) {
		ar(name, parameters, hasReceiver, isMutable, scope);
	}
};

struct FuncDef : public IRNode {
	std::shared_ptr<ValueSymbol> symbol;
	std::vector<std::string> parameters;
	std::shared_ptr<Scope> scope;
	std::shared_ptr<FuncType> type;

	std::any accept(IRVisitor* visitor) override;
	std::string getMangledName() const;
	std::string getNodeName() const override;
	std::string printChildren(const std::string& prefix) const override;

	template<typename Archive>
	void serialize(Archive& ar) {
		ar(symbol, parameters, scope, type);
	}
};

enum class CallKind {
	Free,
	Method,
	MutatingMethod,
	Pipe,
	Operator,
	Subscript,
	Constructor,
};

struct FuncCall : public IRNode {
	CallKind kind = CallKind::Free;
	std::shared_ptr<IRNode> callee;
	std::vector<std::shared_ptr<IRNode>> arguments;

	std::any accept(IRVisitor* visitor) override;
	std::string getNodeName() const override;
	std::string printChildren(const std::string& prefix) const override;

	template<typename Archive>
	void serialize(Archive& ar) {
		ar(kind, callee, arguments);
	}
};

struct StringLiteral : public IRNode {
	std::string value;

	std::any accept(IRVisitor* visitor) override;
	std::string getNodeName() const override;

	template<typename Archive>
	void serialize(Archive& ar) {
		ar(value);
	}
};

struct NumberLiteral : public IRNode {
	std::string value;

	std::any accept(IRVisitor* visitor) override;
	std::string getNodeName() const override;

	template<typename Archive>
	void serialize(Archive& ar) {
		ar(value);
	}
};

struct TupleLiteral : public IRNode {
	std::vector<std::shared_ptr<IRNode>> values;

	std::any accept(IRVisitor* visitor) override;
	std::string getNodeName() const override;
	std::string printChildren(const std::string& prefix) const override;

	template<typename Archive>
	void serialize(Archive& ar) {
		ar(values);
	}
};

} // namespace ir

CEREAL_REGISTER_TYPE(ir::ValueSymbol)
CEREAL_REGISTER_TYPE(ir::TypeSymbol)
CEREAL_REGISTER_TYPE(ir::FuncDef)
CEREAL_REGISTER_TYPE(ir::VarDef)
CEREAL_REGISTER_TYPE(ir::GlobalScope)
CEREAL_REGISTER_TYPE(ir::Scope)
CEREAL_REGISTER_TYPE(ir::FuncCall)
CEREAL_REGISTER_TYPE(ir::StringLiteral)
CEREAL_REGISTER_TYPE(ir::NumberLiteral)
CEREAL_REGISTER_TYPE(ir::TupleLiteral)
CEREAL_REGISTER_TYPE(ir::ReturnStatement)
CEREAL_REGISTER_TYPE(ir::Type)
CEREAL_REGISTER_TYPE(ir::FuncType)
CEREAL_REGISTER_TYPE(ir::Lambda)

CEREAL_REGISTER_POLYMORPHIC_RELATION(ir::IRNode, ir::ValueSymbol)
CEREAL_REGISTER_POLYMORPHIC_RELATION(ir::IRNode, ir::TypeSymbol)
CEREAL_REGISTER_POLYMORPHIC_RELATION(ir::IRNode, ir::FuncDef)
CEREAL_REGISTER_POLYMORPHIC_RELATION(ir::IRNode, ir::VarDef)
CEREAL_REGISTER_POLYMORPHIC_RELATION(ir::IRNode, ir::GlobalScope)
CEREAL_REGISTER_POLYMORPHIC_RELATION(ir::IRNode, ir::Scope)
CEREAL_REGISTER_POLYMORPHIC_RELATION(ir::IRNode, ir::FuncCall)
CEREAL_REGISTER_POLYMORPHIC_RELATION(ir::IRNode, ir::StringLiteral)
CEREAL_REGISTER_POLYMORPHIC_RELATION(ir::IRNode, ir::NumberLiteral)
CEREAL_REGISTER_POLYMORPHIC_RELATION(ir::IRNode, ir::TupleLiteral)
CEREAL_REGISTER_POLYMORPHIC_RELATION(ir::IRNode, ir::ReturnStatement)
CEREAL_REGISTER_POLYMORPHIC_RELATION(ir::IRNode, ir::Type)
CEREAL_REGISTER_POLYMORPHIC_RELATION(ir::IRNode, ir::FuncType)
CEREAL_REGISTER_POLYMORPHIC_RELATION(ir::IRNode, ir::Lambda)
