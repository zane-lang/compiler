#include "nodes.hpp"

namespace ir {

std::any IRVisitor::visit(IRNode* node) {
	if (node) {
		return node->accept(this);
	}
	return {};
}

// ValueSymbol
std::any ValueSymbol::accept(IRVisitor* visitor) {
	return visitor->visitValueSymbol(this);
}

std::string ValueSymbol::getNodeName() const {
	return "ValueSymbol(" + name + ")";
}

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

// TypeSymbol
std::any TypeSymbol::accept(IRVisitor* visitor) {
	return visitor->visitTypeSymbol(this);
}

std::string TypeSymbol::getNodeName() const {
	return "TypeSymbol(" + name + ")";
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

// FuncType
std::any FuncType::accept(IRVisitor* visitor) {
	return visitor->visitFuncType(this);
}

std::string FuncType::getParamString() const {
	if (paramTypes.size() == 0) {
		return "()";
	}
	std::string result = paramTypes[0]->getMangledName();

	for(int i = 1; i < paramTypes.size(); i++) {
		auto type = paramTypes[i];
		result += ", " + type->getMangledName();
	}

	return "(" + result + ")";
}

std::string FuncType::getNodeName() const {
	return "FuncType(" + getMangledName() + ")";
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

// Type
std::any Type::accept(IRVisitor* visitor) {
	return visitor->visitType(this);
}

std::string Type::getMangledName() const {
	std::string name = value.visit([](auto& v) -> std::string {
		return v->getMangledName();
	});

	return name;
}

std::string Type::getNodeName() const {
	std::string nodeName = value.visit([](auto& v) -> std::string {
		return v->getNodeName();
	});

	return "Type(" + nodeName + ")";
}

} // namespace ir
