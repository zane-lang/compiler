#pragma once

#include "zane-cpp.hpp"
#include "semantic/metadata.hpp"

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
			auto elementType = getType(*generic) | zane::pipe([](auto result) {
				return zane::handle(std::move(result), [](const std::string& error) -> llvm::Type* {
					throw std::runtime_error(error);
				});
			});
			auto node = llvm::StructType::create(ctx, "List");
			auto nodePtr = llvm::PointerType::get(ctx, 0);
			node->setBody({elementType, nodePtr});
			return node;
		}}
	};

	// Internal: resolve semantic::Type → llvm::Type* with caching
	auto resolveType(const semantic::Type& type) -> zane::abortable<llvm::Type*, std::string> {
		if (auto it = typeCache.find(type); it != typeCache.end()) {
			return zane::abortable<llvm::Type*, std::string>::success(it->second);
		}

		auto result = type.value.match(
			[this](const std::shared_ptr<semantic::TypeSymbol>& sym) {
				return resolveTypeSymbol(*sym);
			},
			[this](const std::shared_ptr<semantic::FuncType>& func) {
				return resolveFuncType(*func);
			}
		);

		if (result.is_success()) {
			typeCache[type] = result.unwrap();
		}
		return result;
	}

	auto resolveTypeSymbol(const semantic::TypeSymbol& sym) -> zane::abortable<llvm::Type*, std::string> {
		// Generic types (e.g., List<T>)
		if (!sym.generics.empty()) {
			if (!genericTypeConstructors.contains(sym.name)) {
				return zane::abortable<llvm::Type*, std::string>::abort({ "unknown generic type: " + sym.name });
			}
			return zane::abortable<llvm::Type*, std::string>::success(
				genericTypeConstructors.at(sym.name)(ctx, sym.generics[0])
			);
		}
		// Primitive lookup (fallback for unqualified names)
		if (!sym.packageName.has_value() || sym.packageName.value() == "Primitives") {
			return getPrimitiveType(sym.name);
		}
		return zane::abortable<llvm::Type*, std::string>::abort({ "unresolved type: " + sym.getMangledName() });
	}

	auto resolveFuncType(const semantic::FuncType& func) -> zane::abortable<llvm::Type*, std::string> {
		std::vector<llvm::Type*> paramTypes;
		paramTypes.reserve(func.paramTypes.size());
		
		for (const auto& param : func.paramTypes) {
			auto ty = getType(*param);
			if (!ty.is_success()) return ty;
			paramTypes.push_back(ty.unwrap());
		}
		
		auto retTy = getType(*func.returnType);
		if (!retTy.is_success()) return retTy;
		
		return zane::abortable<llvm::Type*, std::string>::success(
			llvm::FunctionType::get(retTy.unwrap(), paramTypes, false)
		);
	}

	auto getPrimitiveType(const std::string& name) -> zane::abortable<llvm::Type*, std::string> {
		if (primitives.contains(name)) {
			return zane::abortable<llvm::Type*, std::string>::success(primitives.at(name));
		}
		return zane::abortable<llvm::Type*, std::string>::abort({ "unknown primitive type: " + name });
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

	// Public API: primitive lookup by name
	auto getType(const std::string& package, const std::string& name) -> zane::abortable<llvm::Type*, std::string> {
		if (package == "Primitives") {
			return getPrimitiveType(name);
		}
		// For "Types" package, caller should use getType(const semantic::Type&) directly
		return zane::abortable<llvm::Type*, std::string>::abort({ 
			"package '" + package + "' requires semantic::Type; use getType(const semantic::Type&) overload" 
		});
	}

	// Public API: resolve any semantic::Type (primitives, generics, functions)
	auto getType(const semantic::Type& type) -> zane::abortable<llvm::Type*, std::string> {
		return resolveType(type);
	}
};
