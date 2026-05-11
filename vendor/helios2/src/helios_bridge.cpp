#include "helios_bridge.hpp"

#include <llvm/IR/DerivedTypes.h>
#include <llvm/IR/Function.h>
#include <llvm/IR/Type.h>

#include <string_view>
#include <vector>

namespace {

std::string_view canonicalTypeName(std::string_view fullTypeName, std::string_view llvmTypeName) {
	return llvmTypeName.empty() ? fullTypeName : llvmTypeName;
}

} // namespace

HeliosBridge::HeliosBridge(llvm::LLVMContext& context, llvm::Module& module)
	: context(context), module(module) {}

llvm::Type* HeliosBridge::builtinType(std::string_view typeName) const {
	if (typeName == "Void" || typeName == "void") {
		return llvm::Type::getVoidTy(context);
	}

	if (typeName == "Bool" || typeName == "bool" || typeName == "i1") {
		return llvm::Type::getInt1Ty(context);
	}

	if (typeName == "i8") {
		return llvm::Type::getInt8Ty(context);
	}

	if (typeName == "i16") {
		return llvm::Type::getInt16Ty(context);
	}

	if (typeName == "i32") {
		return llvm::Type::getInt32Ty(context);
	}

	if (typeName == "I64" || typeName == "i64") {
		return llvm::Type::getInt64Ty(context);
	}

	if (typeName == "f32" || typeName == "float") {
		return llvm::Type::getFloatTy(context);
	}

	if (typeName == "F64" || typeName == "f64" || typeName == "double") {
		return llvm::Type::getDoubleTy(context);
	}

	if (typeName == "String" || typeName == "ptr") {
		return llvm::PointerType::get(context, 0);
	}

	return nullptr;
}

llvm::Type* HeliosBridge::ensureType(std::string_view fullTypeName, std::string_view llvmTypeName) {
	return builtinType(canonicalTypeName(fullTypeName, llvmTypeName));
}

llvm::Function* HeliosBridge::ensureFunction(
		std::string_view fullName,
		std::string_view returnTypeName,
		const std::vector<std::string>& parameterTypeNames,
		std::string_view runtimeSymbol) {
	(void)fullName;

	if (runtimeSymbol.empty()) {
		return nullptr;
	}

	if (auto* function = module.getFunction(runtimeSymbol)) {
		return function;
	}

	auto* returnType = builtinType(returnTypeName);
	if (returnType == nullptr) {
		return nullptr;
	}

	std::vector<llvm::Type*> parameterTypes;
	parameterTypes.reserve(parameterTypeNames.size());
	for (const auto& parameterTypeName : parameterTypeNames) {
		auto* parameterType = builtinType(parameterTypeName);
		if (parameterType == nullptr) {
			return nullptr;
		}
		parameterTypes.push_back(parameterType);
	}

	auto* functionType = llvm::FunctionType::get(returnType, parameterTypes, false);
	return llvm::Function::Create(
		functionType,
		llvm::Function::ExternalLinkage,
		std::string(runtimeSymbol),
		module
	);
}

std::string HeliosBridge::remapTypeName(
		std::string_view fullTypeName,
		std::string_view llvmTypeName) {
	return std::string(canonicalTypeName(fullTypeName, llvmTypeName));
}
