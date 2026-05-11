#include "compiler/intrinsics.hpp"
#include "helios_bridge.hpp"
#include "semantic/metadata.hpp"

#include <llvm/IR/Type.h>
#include <llvm/IR/DerivedTypes.h>
#include <llvm/IR/LLVMContext.h>
#include <string>
#include <string_view>
#include <unordered_map>

class TypeMapper {
private:
	struct ResolvedTypeName {
		std::string fullTypeName;
		std::string llvmTypeName;
	};

	std::unordered_map<std::string, llvm::Type*> typeCache;
	HeliosBridge& bridge;
	llvm::LLVMContext& context;

public:
	TypeMapper(llvm::LLVMContext& ctx, HeliosBridge& heliosBridge)
		: bridge(heliosBridge), context(ctx) {}

	llvm::Type* toLLVMType(const std::string& irTypeName) {
		auto resolvedType = resolveTypeName(irTypeName);
		return toLLVMType(resolvedType.fullTypeName, resolvedType.llvmTypeName);
	}

	llvm::Type* toLLVMType(semantic::Type* irType) {
		std::shared_ptr<llvm::Type*> result;
		irType->value.match(
			[&](std::shared_ptr<semantic::TypeSymbol> ts) {
				auto resolvedType = resolveTypeName(ts.get());
				result = std::make_shared<llvm::Type*>(
					toLLVMType(resolvedType.fullTypeName, resolvedType.llvmTypeName));
			},
			[&](std::shared_ptr<semantic::FuncType> /* ft */) {
				// Function types are represented as pointers in LLVM
				result = std::make_shared<llvm::Type*>(llvm::PointerType::get(context, 0));
			}
		);
		return result ? *result : nullptr;
	}

private:
	llvm::Type* toLLVMType(
			const std::string& fullTypeName,
			const std::string& llvmTypeName) {
		auto it = typeCache.find(fullTypeName);
		if (it != typeCache.end()) {
			return it->second;
		}

		const std::string remappedTypeName =
			HeliosBridge::remapTypeName(fullTypeName, llvmTypeName);
		auto remapped = typeCache.find(remappedTypeName);
		if (remapped != typeCache.end()) {
			typeCache[fullTypeName] = remapped->second;
			return remapped->second;
		}

		llvm::Type* llvmType = bridge.ensureType(fullTypeName, llvmTypeName);
		if (llvmType != nullptr) {
			typeCache[fullTypeName] = llvmType;
			typeCache[remappedTypeName] = llvmType;
		}
		return llvmType;
	}

	ResolvedTypeName resolveTypeName(std::string_view irTypeName) const {
		if (irTypeName == "Void") {
			return {"Void", "void"};
		}

		if (irTypeName == "String") {
			return {"String", "ptr"};
		}

		if (irTypeName == "Bool") {
			return {"Bool", "i1"};
		}

		if (irTypeName == "I64") {
			return {"I64", "i64"};
		}

		if (irTypeName == "F64") {
			return {"F64", "double"};
		}

		std::string fullTypeName(irTypeName);
		std::string llvmTypeName(fullTypeName);
		if (const auto* primitive = intrinsics::get().findPrimitiveForConcept(irTypeName)) {
			fullTypeName = primitive->fullName;
			llvmTypeName = primitive->llvmTypeName;
		}
		else if (const auto* intrinsic = resolveIntrinsicType(irTypeName)) {
			llvmTypeName = intrinsic->llvmTypeName;
		}

		return {std::move(fullTypeName), std::move(llvmTypeName)};
	}

	ResolvedTypeName resolveTypeName(const semantic::TypeSymbol* typeSymbol) const {
		if (typeSymbol == nullptr) {
			return {"Void", "void"};
		}

		std::string baseTypeName = typeSymbol->name;
		if (typeSymbol->packageName.has_value()) {
			baseTypeName =
				semantic::getMangledPackageName(typeSymbol->packageName.value())
				+ "$"
				+ typeSymbol->name;
		}

		auto resolvedType = resolveTypeName(baseTypeName);
		if (typeSymbol->generics.empty()) {
			return resolvedType;
		}

		std::string fullTypeName = resolvedType.fullTypeName + "<";
		for (std::size_t i = 0; i < typeSymbol->generics.size(); ++i) {
			if (i > 0) {
				fullTypeName += ",";
			}

			std::string genericTypeName;
			typeSymbol->generics[i]->value.match(
				[&](std::shared_ptr<semantic::TypeSymbol> genericTypeSymbol) {
					genericTypeName = resolveTypeName(genericTypeSymbol.get()).fullTypeName;
				},
				[&](std::shared_ptr<semantic::FuncType> /* funcType */) {
					genericTypeName = "ptr";
				}
			);
			fullTypeName += genericTypeName;
		}
		fullTypeName += ">";

		resolvedType.fullTypeName = std::move(fullTypeName);
		return resolvedType;
	}

	const intrinsics::IntrinsicInfo* resolveIntrinsicType(std::string_view irTypeName) const {
		if (const auto* intrinsic = intrinsics::get().find(irTypeName)) {
			return intrinsic;
		}

		auto genericStart = irTypeName.find('<');
		if (genericStart == std::string_view::npos) {
			return nullptr;
		}

		return intrinsics::get().find(irTypeName.substr(0, genericStart));
	}
};
