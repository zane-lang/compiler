#include "compiler/compiler.hpp"

#include "globals/mangling.hpp"
#include "globals/paths.hpp"
#include "compiler/zig_toolchain.hpp"
#include "utils/console.hpp"
#include "utils/shell.hpp"

#include <algorithm>
#include <cstdlib>
#include <fstream>
#include <llvm/IR/IRBuilder.h>
#include <llvm/Support/raw_ostream.h>
#include <optional>
#include <sstream>
#include <vector>

namespace {

fs::path getHeliosSourceDir() {
	return fs::path(ZANE_COMPILER_ROOT) / "vendor" / "helios" / "src";
}

std::vector<fs::path> collectHeliosFiles() {
	std::vector<fs::path> files;
	const fs::path sourceDir = getHeliosSourceDir();
	if (!fs::exists(sourceDir) || !fs::is_directory(sourceDir)) {
		return files;
	}

	for (const auto& entry : fs::recursive_directory_iterator(sourceDir)) {
		if (entry.is_regular_file()) {
			files.push_back(entry.path());
		}
	}

	std::sort(files.begin(), files.end());
	return files;
}

std::vector<fs::path> collectHeliosSources() {
	std::vector<fs::path> sources;
	for (const auto& path : collectHeliosFiles()) {
		if (path.extension() == ".c") {
			sources.push_back(path);
		}
	}
	return sources;
}

std::string serializeHeliosInputs(const std::vector<fs::path>& files, BuildMode mode) {
	std::ostringstream serialized;
	serialized << "mode=" << (mode == BuildMode::Release ? "release" : "debug") << '\n';
	for (const auto& path : files) {
		serialized << fs::relative(path, getHeliosSourceDir()).generic_string() << '\n';
	}
	return serialized.str();
}

} // namespace

void Compiler::generateMainWrapper() {
	auto wrapperModule = std::make_unique<llvm::Module>("__main_wrapper", *context);
	llvm::IRBuilder<> builder(*context);

	std::string entryPackage = manifest.name;
	if (manifest.type == manifest::Type::Library) {
		entryPackage = "test";
	}

	std::string mangledMain = constants::getMangledMain(entryPackage);
	llvm::FunctionType* mangledMainType = llvm::FunctionType::get(builder.getVoidTy(), {}, false);
	wrapperModule->getOrInsertFunction(mangledMain, mangledMainType);

	llvm::FunctionType* mainType = llvm::FunctionType::get(
		builder.getInt32Ty(),
		{builder.getInt32Ty(), llvm::PointerType::get(*context, 0)},
		false
	);
	llvm::Function* mainFunc = llvm::Function::Create(
		mainType,
		llvm::Function::ExternalLinkage,
		"main",
		wrapperModule.get()
	);

	llvm::BasicBlock* entry = llvm::BasicBlock::Create(*context, "entry", mainFunc);
	builder.SetInsertPoint(entry);
	builder.CreateCall(wrapperModule->getFunction(mangledMain));
	builder.CreateRet(builder.getInt32(0));

	modules["__main_wrapper"] = std::move(wrapperModule);
}

bool Compiler::compileModuleWithZig(
		llvm::Module& module,
		const fs::path& objectFile,
		const constants::targets::Target& target,
		BuildMode mode) {
	fs::path irFile = fs::path(objectFile).replace_extension(".ll");

	std::error_code errorCode;
	llvm::raw_fd_ostream irOut(irFile.string(), errorCode);
	if (errorCode) {
		llvm::errs() << "Could not write IR: " << errorCode.message() << "\n";
		return false;
	}

	module.print(irOut, nullptr);
	irOut.flush();

	std::string command = zig::path() + " cc"
		+ " --target=" + zig::toZigTarget(target.triple)
		+ (mode == BuildMode::Release ? " -O3" : "")
		+ " -c \"" + irFile.string() + "\""
		+ " -o \"" + objectFile.string() + "\"";

	if (std::system(command.c_str()) != 0) {
		DEBUG("zig cc failed for " << irFile.filename().string());
		return false;
	}

	fs::remove(irFile);
	return true;
}

bool Compiler::compileRuntimeObject(
		const constants::targets::Target& target,
		BuildMode mode,
		const fs::path& cacheDir,
		fs::path& objectFile) {
	const auto runtimeSources = collectHeliosSources();
	if (runtimeSources.empty()) {
		DEBUG("Helios sources not found under: " << getHeliosSourceDir());
		return false;
	}

	objectFile = cacheDir / "__zane_runtime.o";
	const fs::path inputsFile = cacheDir / "__zane_runtime.inputs";
	const auto runtimeInputs = collectHeliosFiles();
	const std::string serializedInputs = serializeHeliosInputs(runtimeInputs, mode);

	auto newestSource = fs::file_time_type::min();
	for (const auto& runtimeInput : runtimeInputs) {
		newestSource = std::max(newestSource, fs::last_write_time(runtimeInput));
	}

	if (
		fs::exists(objectFile)
		&& fs::exists(inputsFile)
		&& fs::last_write_time(objectFile) >= newestSource
	) {
		std::ifstream existingInputs(inputsFile);
		std::stringstream buffer;
		buffer << existingInputs.rdbuf();
		if (buffer.str() == serializedInputs) {
			return true;
		}
	}

	if (!fs::exists(cacheDir)) {
		fs::create_directories(cacheDir);
	}

	if (fs::exists(objectFile)) {
		fs::remove(objectFile);
	}

	if (fs::exists(inputsFile)) {
		fs::remove(inputsFile);
	}

	std::stringstream command;
	command << zig::path() << " cc"
		<< " --target=" << zig::toZigTarget(target.triple)
		<< (mode == BuildMode::Release ? " -O3" : "")
		<< " -c";
	for (const auto& src : runtimeSources) {
		command << " " << shell::quote(src.string());
	}
	command << " -o " << shell::quote(objectFile.string());

	if (std::system(command.str().c_str()) != 0) {
		DEBUG("Failed to compile Helios runtime");
		return false;
	}

	std::ofstream updatedInputs(inputsFile, std::ios::trunc);
	if (!updatedInputs) {
		DEBUG("Failed to write Helios runtime input manifest");
		fs::remove(objectFile);
		return false;
	}
	updatedInputs << serializedInputs;
	updatedInputs.close();
	if (!updatedInputs) {
		DEBUG("Failed to finalize Helios runtime input manifest");
		fs::remove(inputsFile);
		fs::remove(objectFile);
		return false;
	}

	return true;
}

void Compiler::compileToObjectFiles(
		const constants::targets::Target& target,
		BuildMode mode,
		bool clearModules) {
	fs::path cacheDir = fs::path(constants::CACHE_DIR) / target.name;
	if (!fs::exists(cacheDir)) {
		fs::create_directories(cacheDir);
	}

	for (auto& [pkgName, module] : modules) {
		fs::path packagePath = cacheDir;
		if (pkgName != manifest.name && pkgName != "__main_wrapper") {
			packagePath = cacheDir / pkgName;
			fs::create_directories(packagePath);
		}

		compileModuleWithZig(*module, packagePath / (pkgName + ".o"), target, mode);
	}

	PRINT("Generated object files for " << target.name);
	if (clearModules) {
		modules.clear();
	}
}

bool Compiler::linkObjectFiles(
		const constants::targets::Target& target,
		BuildMode mode,
		const std::string& outputExecutable) {
	fs::path cacheDir = fs::path(constants::CACHE_DIR) / target.name;
	std::vector<std::string> objectFiles;
	fs::path runtimeObject;

	if (!compileRuntimeObject(target, mode, cacheDir, runtimeObject)) {
		return false;
	}

	for (const auto& path : getLocalObjectFiles(cacheDir)) {
		if (path == runtimeObject) {
			continue;
		}
		objectFiles.push_back(shell::quote(path.string()));
	}
	objectFiles.push_back(shell::quote(runtimeObject.string()));

	for (const auto& path : getDependencyArtifacts(target)) {
		objectFiles.push_back(shell::quote(path.string()));
	}

	if (objectFiles.empty()) {
		DEBUG("No object files found to link for " << target.name);
		return false;
	}

	std::stringstream command;
	command << zig::path() << " cc"
		<< " --target=" << zig::toZigTarget(target.triple)
		<< (mode == BuildMode::Release ? " -O3" : "");
	for (const auto& objectFile : objectFiles) {
		command << " " << objectFile;
	}
	command << " -o " << shell::quote(outputExecutable);

	PRINT("Linking " << target.name << ": " << command.str());
	if (std::system(command.str().c_str()) != 0) {
		DEBUG("Linking failed for " << target.name);
		return false;
	}

	PRINT("Created executable: " << outputExecutable);
	return true;
}

bool Compiler::createStaticLibrary(
		const constants::targets::Target& target,
		const std::string& outputLibrary) {
	fs::path cacheDir = fs::path(constants::CACHE_DIR) / target.name;
	std::vector<std::string> objectFiles;
	fs::path runtimeObject;

	if (!compileRuntimeObject(target, BuildMode::Release, cacheDir, runtimeObject)) {
		return false;
	}

	for (const auto& path : getLocalObjectFiles(cacheDir)) {
		if (path == runtimeObject) {
			continue;
		}
		objectFiles.push_back(shell::quote(path.string()));
	}
	objectFiles.push_back(shell::quote(runtimeObject.string()));

	const auto dependencyArtifacts = getDependencyArtifacts(target);
	for (const auto& path : dependencyArtifacts) {
		objectFiles.push_back(shell::quote(path.string()));
	}

	std::optional<fs::path> mergedObject;
	if (objectFiles.empty()) {
		DEBUG("No object files found for static library " << target.name);
		return false;
	}

	const fs::path outputPath(outputLibrary);
	fs::create_directories(outputPath.parent_path());

	if (!dependencyArtifacts.empty()) {
		mergedObject =
			outputPath.parent_path() / (outputPath.stem().string() + ".merged.o");
		std::stringstream mergeCommand;
		mergeCommand << zig::path() << " cc"
			<< " --target=" << zig::toZigTarget(target.triple)
			<< " -r";
		for (const auto& objectFile : objectFiles) {
			mergeCommand << " " << objectFile;
		}
		mergeCommand << " -o " << shell::quote(mergedObject->string());

		PRINT("Flattening dependency objects for " << target.name << ": " << mergeCommand.str());
		if (std::system(mergeCommand.str().c_str()) != 0) {
			if (mergedObject.has_value()) {
				fs::remove(*mergedObject);
			}
			DEBUG("Failed to merge dependency objects for " << target.name);
			return false;
		}

		objectFiles = { shell::quote(mergedObject->string()) };
	}

	std::stringstream command;
	command << zig::path() << " ar"
		<< " crs " << shell::quote(outputLibrary);
	for (const auto& objectFile : objectFiles) {
		command << " " << objectFile;
	}

	PRINT("Creating static library " << target.name << ": " << command.str());
	if (std::system(command.str().c_str()) != 0) {
		if (mergedObject.has_value()) {
			fs::remove(*mergedObject);
		}
		DEBUG("Static library creation failed for " << target.name);
		return false;
	}

	if (mergedObject.has_value()) {
		fs::remove(*mergedObject);
	}

	PRINT("Created static library: " << outputLibrary);
	return true;
}

void Compiler::buildForAllTargets() {
	if (!zig::ensure()) {
		DEBUG("Could not acquire Zig toolchain. Aborting.");
		return;
	}

	for (const auto& target : constants::targets::ALL_TARGETS) {
		PRINT("\n=== Building for " << target.name << " ===");

		modules.clear();
		generateCode(target.triple);
		compileToObjectFiles(target, BuildMode::Release, true);

		fs::path buildDir = fs::path(constants::BUILD_DIR) / target.name;
		if (!fs::exists(buildDir)) {
			fs::create_directories(buildDir);
		}

		if (manifest.type == manifest::Type::Executable) {
			std::string executableName = manifest.name + std::string(target.extension);
			fs::path outputPath = buildDir / executableName;
			if (!linkObjectFiles(target, BuildMode::Release, outputPath.string())) {
				DEBUG("Build failed for " << target.name);
			}
		}
		else {
			std::string targetName(target.name);
			std::string libraryExtension =
				(targetName.find("windows") != std::string::npos) ? ".lib" : ".a";
			std::string libraryName = "lib" + manifest.name + libraryExtension;
			fs::path outputPath = buildDir / libraryName;
			if (!createStaticLibrary(target, outputPath.string())) {
				DEBUG("Library creation failed for " << target.name);
			}
		}
	}
}

void Compiler::executeNative(const std::string& executable) {
	if (!fs::exists(executable)) {
		DEBUG("Executable not found: " << executable);
		return;
	}

	PRINT("--- Execution ---");
#ifdef _WIN32
	(void)std::system(("\"" + executable + "\"").c_str());
#else
	(void)std::system(("./" + executable).c_str());
#endif
}
