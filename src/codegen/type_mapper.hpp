#include "semantic/metadata.hpp"
#include <unordered_map>
#include <string>
#include <llvm/IR/Type.h>
#include <llvm/IR/DerivedTypes.h>
#include <llvm/IR/LLVMContext.h>
#include <utils/embedded_types.hpp>

class TypeMapper {
private:
	std::unordered_map<std::string, llvm::Type*> typeCache;
	llvm::LLVMContext& context;

public:
	TypeMapper(llvm::LLVMContext& ctx) : context(ctx) {
		loadTypes();
	}

	llvm::Type* toLLVMType(const std::string& irTypeName) {
		if (irTypeName == "String") {
			return llvm::PointerType::get(context, 0);
		}
		auto it = typeCache.find(irTypeName);
		if (it != typeCache.end()) {
			return it->second;
		}
		return nullptr;
	}

	llvm::Type* toLLVMType(semantic::Type* irType) {
		std::shared_ptr<llvm::Type*> result;
		irType->value.match(
			[&](std::shared_ptr<semantic::TypeSymbol> ts) {
				result = std::make_shared<llvm::Type*>(toLLVMType(ts->getMangledName()));
			},
			[&](std::shared_ptr<semantic::FuncType> ft) {
				llvm::Type* retType = toLLVMType(ft->returnType.get());
				std::vector<llvm::Type*> params;
				for (auto& p : ft->paramTypes) {
					params.push_back(toLLVMType(p.get()));
				}
				llvm::FunctionType* funcType = llvm::FunctionType::get(retType, params, false);
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
		return nullptr;
	}

	void loadTypes() {
		for (const auto& typeInfo : utils::parseEmbeddedTypes()) {
			typeCache[typeInfo.name] = resolveString(typeInfo.llvmType);
		}
	}
};
