#include "package/package.hpp"

#include "codegen/llvm.hpp"

std::unique_ptr<llvm::Module> Package::getLlvmModule(
		zane::ref<llvm::LLVMContext> context,
		zane::ref<Package> package,
		zane::ref<Packages> allPackages,
		const std::vector<std::shared_ptr<semantic::PackageInfo>>& externalPackages,
		const std::string& triple) {
	LLVMCodeGen codegen(context.get(), triple);
	codegen.setupBuiltins();
	codegen.generate(package, allPackages, externalPackages);
	return codegen.extractModule();
}
