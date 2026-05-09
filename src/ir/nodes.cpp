#include "nodes.hpp"

namespace ir {

std::string ValueSymbol::getMangledName() const {
	std::string suffix = "";
	if (type) {
		type->value.match([&](std::shared_ptr<FuncType> funcType) {
			suffix = funcType->getParamString();
		});
	}
	std::string prefix = "";
	if (packageName.has_value()) {
		prefix = getMangledPackageName(packageName.value()) + "$";
	}
	return prefix + name + suffix;
}

std::string TypeSymbol::getMangledName() const {
	std::string result = "";
	if (packageName.has_value()) {
		result = getMangledPackageName(packageName.value()) + "$" + name;
	}
	else {
		result = name;
	}

	if (generics.size() > 0) {
		result += "<";
		for (auto type : generics) {
			result += type->getMangledName();
			result += ",";
		}
		result += ">";
	}
	return result;
}

std::string FuncType::getParamString() const {
	if (paramTypes.size() == 0) {
		return "()";
	}
	std::string result = paramTypes[0]->getMangledName();

	for (std::size_t i = 1; i < paramTypes.size(); ++i) {
		auto type = paramTypes[i];
		result += ", " + type->getMangledName();
	}

	return "(" + result + ")";
}

std::string FuncType::getMangledName() const {
	return "&Function";
}

bool FuncType::operator==(const FuncType& other) const {
    if (paramTypes.size() != other.paramTypes.size()) return false;
    if (returnType->getMangledName() != other.returnType->getMangledName()) return false;
    for (int i = 0; i < (int)paramTypes.size(); i++) {
        if (paramTypes[i]->getMangledName() != other.paramTypes[i]->getMangledName()) return false;
    }
    return true;
}

std::string Type::getMangledName() const {
	std::string name = value.visit([](auto& v) -> std::string {
		return v->getMangledName();
	});

	return name;
}

} // namespace ir
