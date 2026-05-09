#include "compiler/compiler.hpp"

#include "ast/symbol_collector.hpp"
#include "globals/package_cache.hpp"
#include "package/package.hpp"
#include "semantic/metadata.hpp"

Compiler::ResolvedDependency Compiler::resolveDependency(
		const std::string& alias,
		const manifest::Dependency& dependency) {
	ResolvedDependency resolved;
	resolved.alias = alias;
	resolved.url = dependency.url;
	resolved.tag = dependency.tag;
	resolved.srcRoot = constants::getPackageSrcPath(dependency.url, dependency.tag);
	resolved.buildRoot = constants::getPackageBuildPath(dependency.url, dependency.tag);

	const fs::path dependencyManifestPath =
		resolved.srcRoot / constants::MANIFEST_PATH;
	if (fs::exists(dependencyManifestPath)) {
		manifest::Manifest dependencyManifest(dependencyManifestPath.string().c_str());
		resolved.packageName = dependencyManifest.name;
		resolved.usesVersionedSymbols =
			!resolved.packageName.empty()
			&& constants::packageBuildUsesVersionedSymbols(
				resolved.buildRoot,
				resolved.packageName,
				resolved.tag
			);
	}

	return resolved;
}

void Compiler::collectLinkedDependencies(
		const manifest::Manifest& currentManifest,
		std::set<std::string>& visited) {
	for (const auto& [alias, dependency] : currentManifest.dependencies) {
		const std::string cacheKey = dependency.url + "@" + dependency.tag;
		if (!visited.insert(cacheKey).second) {
			continue;
		}

		auto resolved = resolveDependency(alias, dependency);
		linkedDependencies.push_back(resolved);

		const fs::path dependencyManifestPath =
			resolved.srcRoot / constants::MANIFEST_PATH;
		if (!fs::exists(dependencyManifestPath)) {
			continue;
		}

		manifest::Manifest dependencyManifest(dependencyManifestPath.string().c_str());
		collectLinkedDependencies(dependencyManifest, visited);
	}
}

void Compiler::prepareDependencies() {
	if (dependenciesPrepared) {
		return;
	}

	dependenciesPrepared = true;

	std::set<std::string> visited;
	for (const auto& [alias, dependency] : manifest.dependencies) {
		directDependencies.push_back(resolveDependency(alias, dependency));
	}

	collectLinkedDependencies(manifest, visited);
}

void Compiler::loadExternalPackageSymbols() {
	prepareDependencies();
	externalPackageInfos.clear();

	for (const auto& dependency : directDependencies) {
		const fs::path sourceDir =
			dependency.srcRoot / constants::library::LIBRARY_DIR;
		auto sourceFiles = collectSourceFiles(sourceDir);
		if (sourceFiles.empty()) {
			continue;
		}

		Package externalPackage(*symbolCollector);
		externalPackage.parse(sourceFiles);
		externalPackage.collectSymbols();

		std::shared_ptr<semantic::PackageInfo> packageInfo;
		if (!dependency.packageName.empty()) {
			packageInfo = symbolCollector->getPackageInfo(dependency.packageName);
		}

		if (!packageInfo) {
			packageInfo = externalPackage.getPackageInfo();
		}

		if (!packageInfo) {
			continue;
		}

		externalPackageInfos.push_back(packageInfo);

		if (dependency.usesVersionedSymbols && !dependency.packageName.empty()) {
			semantic::setVersionedPackageName(dependency.packageName, dependency.tag);
		}

		if (!dependency.alias.empty()) {
			symbolCollector->registerPackageAlias(dependency.alias, packageInfo);
		}
	}
}

std::vector<fs::path> Compiler::getLocalObjectFiles(const fs::path& cacheDir) {
	std::vector<fs::path> objectFiles;
	if (!fs::exists(cacheDir)) {
		return objectFiles;
	}

	for (const auto& entry : fs::recursive_directory_iterator(cacheDir)) {
		if (!entry.is_regular_file()) {
			continue;
		}

		const auto extension = entry.path().extension().string();
		if (extension == ".o" || extension == ".obj") {
			objectFiles.push_back(entry.path());
		}
	}

	return objectFiles;
}

std::vector<fs::path> Compiler::getDependencyArtifacts(
		const constants::targets::Target& target) {
	prepareDependencies();

	std::vector<fs::path> artifacts;
	for (const auto& dependency : linkedDependencies) {
		const fs::path targetBuildDir = dependency.buildRoot / target.name;
		if (!fs::exists(targetBuildDir)) {
			continue;
		}

		for (const auto& entry : fs::recursive_directory_iterator(targetBuildDir)) {
			if (!entry.is_regular_file()) {
				continue;
			}

			if (!constants::isPackageArtifact(entry.path())) {
				continue;
			}

			artifacts.push_back(entry.path());
		}
	}

	return artifacts;
}
