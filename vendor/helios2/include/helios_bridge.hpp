#pragma once

#include <llvm/IR/Function.h>
#include <llvm/IR/LLVMContext.h>
#include <llvm/IR/Module.h>
#include <llvm/IR/Type.h>

#include <string>
#include <string_view>
#include <vector>

class HeliosBridge {
public:
	HeliosBridge(llvm::LLVMContext& context, llvm::Module& module);

	llvm::Type* ensureType(std::string_view fullTypeName, std::string_view llvmTypeName);
	llvm::Function* ensureFunction(
		std::string_view fullName,
		std::string_view returnTypeName,
		const std::vector<std::string>& parameterTypeNames,
		std::string_view runtimeSymbol
	);

	static std::string remapTypeName(std::string_view fullTypeName, std::string_view llvmTypeName);

private:
	llvm::LLVMContext& context;
	llvm::Module& module;

	llvm::Type* builtinType(std::string_view typeName) const;
};
