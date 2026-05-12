#pragma once

#include <llvm/IR/LLVMContext.h>
#include <map>
#include <string>
#include <vector>

// this is just a skeleton structure, it needs implementation

struct Type {
	std::string package;
	std::string name;
	std::vector<int> parameters;
	std::vector<Type> generics;
};

llvm::LLVMContext context;

std::map<std::string, std::string> primitives = {
	{ "Int", "i64" },
	{"Float", "float"},
	{ "String", "ptr" },
	{ "Bool", "i1" }
};

namespace Helios {
std::string getTypeName(const Type& type) {
	if (type.package == "Primitives") return primitives[type.name];
}

void registerType(context, Type generics) {
}
}
