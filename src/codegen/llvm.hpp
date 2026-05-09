#pragma once

#include "codegen/visitor.hpp"
#include "utils/aliases.hpp"

#include <zane-cpp.hpp>
#include <llvm/IR/Module.h>
#include <llvm/IR/IRBuilder.h>
#include <llvm/MC/TargetRegistry.h>
#include <llvm/Target/TargetMachine.h>
#include <memory>

class LLVMCodeGen {
private:
	llvm::LLVMContext& context;
	std::unique_ptr<llvm::Module> module;
	llvm::IRBuilder<> builder;

public:
	LLVMCodeGen(llvm::LLVMContext& ctx, const std::string& triple)
	: context(ctx), module(std::make_unique<llvm::Module>("zane", ctx)), builder(ctx) {
		if (!triple.empty()) {
			module->setTargetTriple(llvm::Triple(triple));
		}
		DEBUG("LLVMCodeGen triple: " << triple);
	}

	void generate(
			zane::ref<Package> package,
			zane::ref<Packages> allPackages,
			const std::vector<std::shared_ptr<semantic::PackageInfo>>& externalPackages = {}) {
		LLVMVisitor visitor(context, builder, *module);
		for (auto& [name, pkg] : *allPackages)
			visitor.declareSignatures(*pkg);
		for (const auto& packageInfo : externalPackages)
			visitor.declareSignatures(packageInfo);
		visitor.generateBodies(package);
	}

	void setupBuiltins() {
		llvm::Type* i8Ptr = llvm::PointerType::get(context, 0);
		llvm::FunctionType* putsType = llvm::FunctionType::get(
			builder.getInt32Ty(), {i8Ptr}, false);
		module->getOrInsertFunction("puts", putsType);
	}

	std::unique_ptr<llvm::Module> extractModule() {
		return std::move(module);
	}

	void writeLLVMIR(const std::string& filename) {
		std::error_code EC;
		llvm::raw_fd_ostream file(filename, EC);
		if (EC) {
			llvm::errs() << "Error opening file: " << EC.message() << "\n";
			return;
		}
		module->print(file, nullptr);
	}
};
