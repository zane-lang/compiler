#pragma once

#include "ast/symbol_collector.hpp"
#include "cli/manifest.hpp"
#include "globals/targets.hpp"
#include "package/package.hpp"
#include "utils/aliases.hpp"

#include <zane-cpp.hpp>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <sstream>
#include <string>
#include <vector>
#include <nlohmann/json.hpp>

enum class BuildMode {
	Dev,
	Release
};

namespace llvm {
	class LLVMContext;
	class Module;
}

class Compiler {
private:
	std::unique_ptr<Packages> packages;
	std::unique_ptr<SymbolCollector> symbolCollector;
	Modules modules;
	manifest::Manifest manifest;
	std::unique_ptr<llvm::LLVMContext> context;
	bool dependenciesPrepared = false;
	std::vector<std::shared_ptr<semantic::PackageInfo>> externalPackageInfos;

	struct ResolvedDependency {
		std::string alias;
		std::string url;
		std::string tag;
		std::string packageName;
		fs::path srcRoot;
		fs::path buildRoot;
		bool usesVersionedSymbols = false;
	};

	std::vector<ResolvedDependency> directDependencies;
	std::vector<ResolvedDependency> linkedDependencies;

	struct SourceDir {
		fs::path dir;
		std::string rootPkgKey;
	};

	std::vector<SourceDir> getIncludedDirectories();
	std::vector<fs::path> collectSourceFiles(const fs::path& dir);
	ResolvedDependency resolveDependency(
		const std::string& alias,
		const manifest::Dependency& dependency);
	void collectLinkedDependencies(
		const manifest::Manifest& currentManifest,
		std::set<std::string>& visited);
	void prepareDependencies();
	void loadExternalPackageSymbols();
	std::vector<fs::path> getLocalObjectFiles(const fs::path& cacheDir);
	std::vector<fs::path> getDependencyArtifacts(const constants::targets::Target& target);
	fs::file_time_type getLastModified(const fs::path& path);
	fs::file_time_type getPackageLastModified(const fs::path& packageDir);
	bool isCacheValid(const fs::path& packageDir);
	void compilePackage(
		const std::string& pkgName,
		const std::vector<fs::path>& files);
	void generateMainWrapper();
	bool compileModuleWithZig(
		llvm::Module& module,
		const fs::path& objectFile,
		const constants::targets::Target& target,
		BuildMode mode);

public:
	Compiler(manifest::Manifest manifest);
	~Compiler();

	void compile();
	zane::ref<Packages> getPackages();
	void generateCode(const std::string& targetTriple = "");
	std::unique_ptr<llvm::Module> linkLlvmModules();
	void compileToObjectFiles(
		const constants::targets::Target& target,
		BuildMode mode,
		bool clearModules = false);
	bool linkObjectFiles(
		const constants::targets::Target& target,
		BuildMode mode,
		const std::string& outputExecutable);
	bool createStaticLibrary(
		const constants::targets::Target& target,
		const std::string& outputLibrary);
	void buildForAllTargets();
	void executeNative(const std::string& executable);
	void writeModules();
	void writeLLVMIR(llvm::Module& module, const std::string& filename);
};
