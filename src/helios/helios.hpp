#pragma once

#include "zane-cpp.hpp"
#include "semantic/metadata.hpp"

#include <expected>  // C++23
#include <llvm/IR/LLVMContext.h>
#include <llvm/IR/Type.h>
#include <llvm/IR/DerivedTypes.h>
#include <llvm/IR/Function.h>
#include <unordered_map>
#include <vector>
#include <map>
#include <functional>
#include <memory>
#include <string>

class Helios {
	llvm::LLVMContext& ctx;
	std::unordered_map<std::string, llvm::Type*> primitives;
	std::unordered_map<semantic::Type, llvm::Type*> typeCache;

	std::map<std::string, std::function<llvm::Type*(llvm::LLVMContext&, std::shared_ptr<semantic::Type>)>> genericTypeConstructors = {
		{"List", [this](llvm::LLVMContext& ctx, std::shared_ptr<semantic::Type> generic) {
			// std::expected doesn't pipe; handle error by throwing (preserves original semantics)
			auto elemResult = getType(*generic);
			if (!elemResult) {
				throw std::runtime_error(elemResult.error());
			}
			llvm::Type* elementType = elemResult.value();
			
			auto node = llvm::StructType::create(ctx, "List");
			auto nodePtr = llvm::PointerType::get(ctx, 0);
			node->setBody({elementType, nodePtr});
			return node;
		}}
	};

	auto resolveType(const semantic::Type& type) -> std::expected<llvm::Type*, std::string> {
		if (auto it = typeCache.find(type); it != typeCache.end()) {
			return it->second;
		}

		std::expected<llvm::Type*, std::string> result = type.value.match(
			[this](const std::shared_ptr<semantic::TypeSymbol>& sym) {
				return resolveTypeSymbol(*sym);
			},
			[this](const std::shared_ptr<semantic::FuncType>& func) {
				return resolveFuncType(*func);
			}
		);

		if (result) {
			typeCache[type] = result.value();
		}
		return result;
	}

	auto resolveTypeSymbol(const semantic::TypeSymbol& sym) -> std::expected<llvm::Type*, std::string> {
		if (!sym.generics.empty()) {
			if (!genericTypeConstructors.contains(sym.name)) {
				return std::unexpected { "unknown generic type: " + sym.name };
			}
			return genericTypeConstructors.at(sym.name)(ctx, sym.generics[0]);
		}
		return getPrimitiveType(sym.name);
	}

	auto resolveFuncType(const semantic::FuncType& func) -> std::expected<llvm::Type*, std::string> {
		std::vector<llvm::Type*> paramTypes;
		paramTypes.reserve(func.paramTypes.size());
		
		for (const auto& param : func.paramTypes) {
			auto ty = getType(*param);
			if (!ty) return ty;  // implicit conversion: expected<T,E> → expected<U,E> works for same E
			paramTypes.push_back(ty.value());
		}
		
		auto retTy = getType(*func.returnType);
		if (!retTy) return retTy;
		
		return llvm::FunctionType::get(retTy.value(), paramTypes, false);
	}

	auto getPrimitiveType(const std::string& name) -> std::expected<llvm::Type*, std::string> {
		if (primitives.contains(name)) {
			return primitives.at(name);
		}
		return std::unexpected{ "unknown primitive type: " + name };
	}

public:
	Helios(llvm::LLVMContext& ctx) : ctx(ctx), primitives({
		{ "Bool", llvm::Type::getInt1Ty(ctx) },
		{ "I8", llvm::Type::getInt8Ty(ctx) },
		{ "I16", llvm::Type::getInt16Ty(ctx) },
		{ "I32", llvm::Type::getInt32Ty(ctx) },
		{ "I64", llvm::Type::getInt64Ty(ctx) },
		{ "F32", llvm::Type::getFloatTy(ctx) },
		{ "F64", llvm::Type::getDoubleTy(ctx) },
	}) {}
	
	auto getType(const semantic::Type& type) -> std::expected<llvm::Type*, std::string> {
		return resolveType(type);
	}
};
