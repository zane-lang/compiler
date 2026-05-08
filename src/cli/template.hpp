#pragma once

#include "cli/manifest.hpp"
#include "globals/project_templates.hpp"
#include "utils/file_io.hpp"

namespace templ {

inline void createLibrary(const std::string& dir, const std::string& libraryName) {
	auto file = dir + constants::library::ENTRY;
	auto content = constants::library::getEntryContent(libraryName);
	writeFile(file, content);

	file = dir + constants::library::LIBRARY;
	content = constants::library::getLibraryContent(libraryName);
	writeFile(file, content);
}

inline void createExecutable(const std::string& dir) {
	auto file = dir + constants::executable::ENTRY;
	auto content = constants::executable::getEntryContent();
	writeFile(file, content);
}

inline void create(const manifest::Manifest& manifest, const std::string& dir) {
	manifest.save();

	if (manifest.type == manifest::Type::Library) {
		createLibrary(dir, manifest.name);
	}
	else if (manifest.type == manifest::Type::Executable) {
		createExecutable(dir);
	}
}

} // namespace templ
