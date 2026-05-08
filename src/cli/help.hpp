#pragma once

#include <string>
#include <map>

namespace help {

const std::map<std::string, std::string> commandHelp = {
	{ "run", "Execute the project (compiles and runs for host platform)" },
	{ "build", "Build the project for all target platforms" },
	{ "debug", "Display the parsed frontend AST" },
	{ "ir", "Dump the LLVM IR to stdout" },
	{ "init", "Initialize a new Zane project in the specified directory" },
	{ "help", "Display help information for commands" },
};

} // namespace help
