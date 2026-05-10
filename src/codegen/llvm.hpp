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

		// @Functions$printLine(ptr) -> void — implemented via puts
		llvm::FunctionType* printLineType =
			llvm::FunctionType::get(builder.getVoidTy(), {i8Ptr}, false);
		llvm::Function* printLine = llvm::Function::Create(
			printLineType,
			llvm::Function::ExternalLinkage,
			"@Functions$printLine",
			module.get());
		printLine->getArg(0)->setName("text");
		{
			llvm::BasicBlock* bb =
				llvm::BasicBlock::Create(context, "entry", printLine);
			builder.SetInsertPoint(bb);
			auto* putsFunc = module->getFunction("puts");
			builder.CreateCall(putsFunc, {printLine->getArg(0)});
			builder.CreateRetVoid();
		}

		// @Functions$stringFromText(ptr) -> ptr — identity (string literal is already a ptr)
		llvm::FunctionType* stringFromTextType =
			llvm::FunctionType::get(i8Ptr, {i8Ptr}, false);
		llvm::Function* stringFromText = llvm::Function::Create(
			stringFromTextType,
			llvm::Function::ExternalLinkage,
			"@Functions$stringFromText",
			module.get());
		stringFromText->getArg(0)->setName("text");
		{
			llvm::BasicBlock* bb =
				llvm::BasicBlock::Create(context, "entry", stringFromText);
			builder.SetInsertPoint(bb);
			builder.CreateRet(stringFromText->getArg(0));
		}
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
