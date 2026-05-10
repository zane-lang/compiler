#include "compiler/intrinsics.hpp"
#include "semantic/metadata.hpp"

#include <llvm/IR/Type.h>
#include <llvm/IR/DerivedTypes.h>
#include <llvm/IR/LLVMContext.h>
#include <string>
#include <unordered_map>

class TypeMapper {
private:
	std::unordered_map<std::string, llvm::Type*> typeCache;
	llvm::LLVMContext& context;

public:
	TypeMapper(llvm::LLVMContext& ctx) : context(ctx) {
		loadTypes();
	}

	llvm::Type* toLLVMType(const std::string& irTypeName) {
		auto it = typeCache.find(irTypeName);
		if (it != typeCache.end()) {
			return it->second;
		}

		if (const auto* intrinsic = intrinsics::get().find(irTypeName)) {
			llvm::Type* llvmType = resolveString(intrinsic->llvmTypeName);
			if (llvmType != nullptr) {
				typeCache[irTypeName] = llvmType;
				return llvmType;
			}
		}

		return nullptr;
	}

	llvm::Type* toLLVMType(semantic::Type* irType) {
		std::shared_ptr<llvm::Type*> result;
		irType->value.match(
			[&](std::shared_ptr<semantic::TypeSymbol> ts) {
				result = std::make_shared<llvm::Type*>(toLLVMType(ts->getMangledName()));
			},
			[&](std::shared_ptr<semantic::FuncType> /* ft */) {
				// Function types are represented as pointers in LLVM
				result = std::make_shared<llvm::Type*>(llvm::PointerType::get(context, 0));
			}
		);
		return result ? *result : nullptr;
	}

private:
	llvm::Type* resolveString(const std::string& llvmTypeName) {
		if (llvmTypeName == "void") return llvm::Type::getVoidTy(context);
		if (llvmTypeName == "i32")  return llvm::Type::getInt32Ty(context);
		if (llvmTypeName == "i64")  return llvm::Type::getInt64Ty(context);
		if (llvmTypeName == "ptr")  return llvm::PointerType::get(context, 0);
		return nullptr;
	}

	void loadTypes() {
		typeCache["Void"] = llvm::Type::getVoidTy(context);
		typeCache["String"] = llvm::PointerType::get(context, 0);

		for (const auto& [fullName, intrinsic] : intrinsics::get().all()) {
			(void)fullName;
			if (!intrinsic.isType()) {
				continue;
			}

			if (llvm::Type* llvmType = resolveString(intrinsic.llvmTypeName)) {
				typeCache[intrinsic.fullName] = llvmType;
			}
		}
	}
};
