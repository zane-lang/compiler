#pragma once

#include "zane-cpp.hpp"
#include "semantic/metadata.hpp"

#include <llvm/IR/LLVMContext.h>
#include <llvm/IR/Type.h>
#include <llvm/IR/DerivedTypes.h>
#include <unordered_map>
#include <vector>

class Helios {
	llvm::LLVMContext& ctx;
	std::unordered_map<std::string, llvm::Type*> primitives;
	std::unordered_map<semantic::Type, llvm::Type*> typeCache;

	std::map<std::string, std::function<llvm::StructType*(llvm::LLVMContext&, semantic::Type)>> genericTypeConstructors = {
		{"List", [this](llvm::LLVMContext& ctx, semantic::Type generic) {
			llvm::Type* elementType = resolveSemanticType(generic);
			auto node = llvm::StructType::create(ctx, "List");
			auto nodePtr = llvm::PointerType::get(ctx, 0);
			node->setBody({elementType, nodePtr});
			return node;
		}}
	};

	auto ensureGenericType(semantic::Type& type) -> zane::abortable<llvm::Type*, std::string> {
		if (typeCache.contains(type)) {
			return zane::abortable<llvm::Type*, std::string>::success(typeCache.at(type));
		}
		// Assuming type.value holds std::shared_ptr<semantic::TypeSymbol> or std::shared_ptr<semantic::FuncType>
		std::string name = type.value.match(
			[](const std::shared_ptr<semantic::TypeSymbol>& arg) -> std::string { 
				return arg->name; 
			}
		);
		
		if (!genericTypeConstructors.contains(name)) {
			return zane::abortable<llvm::Type*, std::string>::abort({ "unknown generic type: " + name });
		}
		return genericTypeConstructors.at(type.value)(ctx, type.generics[0]);
	}

	auto getPrimitiveType(const std::string& name) -> zane::abortable<llvm::Type*, std::string> {
		if (primitives.contains(name)) {
			auto result = primitives.at(name);
			return zane::abortable<llvm::Type*, std::string>::success(result);
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


	auto getType(const std::string& package, const std::string& name) -> zane::abortable<llvm::Type*, std::string> {
		if (package == "Primitives") {
			return getPrimitiveType(name);
		}
		else if (package == "Types") {
			
		}
		return zane::abortable<llvm::Type*, std::string>::abort({ "unknown package: " + package });
	}
};
