#include "nodes.hpp"

#include <sstream>

namespace ir {

namespace {

std::string qualifyName(
		const std::optional<std::string>& packageName,
		const std::string& name) {
	if (!packageName.has_value()) {
		return name;
	}

	return packageName.value() + "$" + name;
}

std::string formatTypeList(
		const std::vector<std::shared_ptr<Type>>& types,
		bool hasReceiver) {
	std::ostringstream oss;
	oss << "(";
	for (size_t i = 0; i < types.size(); ++i) {
		if (i > 0) {
			oss << ", ";
		}
		if (hasReceiver && i == 0) {
			oss << "this ";
		}
		oss << types[i]->getMangledName();
	}
	oss << ")";
	return oss.str();
}

std::string callKindToString(CallKind kind) {
	switch (kind) {
		case CallKind::Free:
			return "FuncCall";
		case CallKind::Method:
			return "MethodCall";
		case CallKind::MutatingMethod:
			return "MutatingMethodCall";
		case CallKind::Pipe:
			return "PipeCall";
		case CallKind::Operator:
			return "OperatorCall";
		case CallKind::Subscript:
			return "SubscriptCall";
		case CallKind::Constructor:
			return "ConstructorCall";
	}

	return "FuncCall";
}

} // namespace

std::any ValueSymbol::accept(IRVisitor* visitor) {
	return visitor->visitValueSymbol(this);
}

std::string ValueSymbol::getNodeName() const {
	return "ValueSymbol(" + qualifyName(packageName, name) + ")";
}

std::string ValueSymbol::getMangledName() const {
	std::string suffix;
	if (type) {
		type->value.match([&](std::shared_ptr<FuncType> funcType) {
			suffix = funcType->getParamString();
		});
	}
	std::string prefix;
	if (packageName.has_value()) {
		prefix = getMangledPackageName(packageName.value()) + "$";
	}
	return prefix + name + suffix;
}

std::any TypeSymbol::accept(IRVisitor* visitor) {
	return visitor->visitTypeSymbol(this);
}

std::string TypeSymbol::getNodeName() const {
	return "TypeSymbol(" + qualifyName(packageName, name) + ")";
}

std::string TypeSymbol::getMangledName() const {
	std::string result;
	if (packageName.has_value()) {
		result = getMangledPackageName(packageName.value()) + "$" + name;
	} else {
		result = name;
	}

	if (!generics.empty()) {
		result += "<";
		for (size_t i = 0; i < generics.size(); ++i) {
			if (i > 0) {
				result += ", ";
			}
			result += generics[i]->getMangledName();
		}
		result += ">";
	}
	return result;
}

std::any GlobalScope::accept(IRVisitor* visitor) {
	return visitor->visitGlobalScope(this);
}

std::string GlobalScope::getNodeName() const {
	return "GlobalScope";
}

std::string GlobalScope::printChildren(const std::string& prefix) const {
	return printNodeVector(body, prefix);
}

std::any FuncType::accept(IRVisitor* visitor) {
	return visitor->visitFuncType(this);
}

std::string FuncType::getParamString() const {
	return formatTypeList(paramTypes, hasReceiver);
}

std::string FuncType::getNodeName() const {
	std::ostringstream oss;
	oss << "FuncType(" << getParamString();
	if (isMutable) {
		oss << " mut";
	}
	oss << " -> ";
	if (returnType) {
		oss << returnType->getMangledName();
	} else {
		oss << "Void";
	}
	if (abortType) {
		oss << " ? " << abortType->getMangledName();
	}
	oss << ")";
	return oss.str();
}

std::string FuncType::getMangledName() const {
	return "&Function";
}

bool FuncType::operator==(const FuncType& other) const {
	if (paramTypes.size() != other.paramTypes.size()) return false;
	if ((returnType == nullptr) != (other.returnType == nullptr)) return false;
	if ((abortType == nullptr) != (other.abortType == nullptr)) return false;
	if (hasReceiver != other.hasReceiver || isMutable != other.isMutable) return false;
	if (returnType && returnType->getMangledName() != other.returnType->getMangledName()) return false;
	if (abortType && abortType->getMangledName() != other.abortType->getMangledName()) return false;
	for (size_t i = 0; i < paramTypes.size(); ++i) {
		if (paramTypes[i]->getMangledName() != other.paramTypes[i]->getMangledName()) return false;
	}
	return true;
}

std::any Type::accept(IRVisitor* visitor) {
	return visitor->visitType(this);
}

std::string Type::getMangledName() const {
	auto name = value.visit([](auto& v) -> std::string {
		return v->getMangledName();
	});

	if (isRef) {
		return "ref " + name;
	}

	return name;
}

std::string Type::getNodeName() const {
	auto nodeName = value.visit([](auto& v) -> std::string {
		return v->getNodeName();
	});

	if (isRef) {
		return "Type(ref " + nodeName + ")";
	}

	return "Type(" + nodeName + ")";
}

std::any Scope::accept(IRVisitor* visitor) {
	return visitor->visitScope(this);
}

std::string Scope::getNodeName() const {
	return "Scope";
}

std::string Scope::printChildren(const std::string& prefix) const {
	return printNodeVector(statements, prefix);
}

std::any ReturnStatement::accept(IRVisitor* visitor) {
	return visitor->visitReturnStatement(this);
}

std::string ReturnStatement::getNodeName() const {
	return "ReturnStatement";
}

std::any Lambda::accept(IRVisitor* visitor) {
	return visitor->visitLambda(this);
}

std::string Lambda::getNodeName() const {
	std::ostringstream oss;
	oss << "Lambda(";
	for (size_t i = 0; i < parameters.size(); ++i) {
		if (i > 0) {
			oss << ", ";
		}
		oss << parameters[i];
	}
	oss << ")";
	if (isMutable) {
		oss << " mut";
	}
	return oss.str();
}

std::string Lambda::printChildren(const std::string& prefix) const {
	if (scope) return scope->printTree(prefix, true);
	return "";
}

std::any FuncDef::accept(IRVisitor* visitor) {
	return visitor->visitFuncDef(this);
}

std::string FuncDef::getMangledName() const {
	return symbol->getMangledName();
}

std::string FuncDef::getNodeName() const {
	std::ostringstream oss;
	oss << "FuncDef(" << symbol->getNodeName();
	if (type) {
		oss << ", " << type->getNodeName();
	}
	oss << ")";
	return oss.str();
}

std::string FuncDef::printChildren(const std::string& prefix) const {
	if (scope) return scope->printTree(prefix, true);
	return "";
}

std::any VarDef::accept(IRVisitor* visitor) {
	return visitor->visitVarDef(this);
}

std::string VarDef::getNodeName() const {
	if (!symbol || !symbol->type) {
		return "VarDef";
	}

	return "VarDef(" + symbol->name + ": " + symbol->type->getMangledName() + ")";
}

std::string VarDef::printChildren(const std::string& prefix) const {
	if (!value) {
		return "";
	}
	return value->printTree(prefix, true);
}

std::any FuncCall::accept(IRVisitor* visitor) {
	return visitor->visitFuncCall(this);
}

std::string FuncCall::getNodeName() const {
	return callKindToString(kind);
}

std::string FuncCall::printChildren(const std::string& prefix) const {
	std::string result;
	bool isCalleeLast = arguments.empty();
	if (callee) {
		result += callee->printTree(prefix, isCalleeLast);
	}
	result += printNodeVector(arguments, prefix);
	return result;
}

std::any StringLiteral::accept(IRVisitor* visitor) {
	return visitor->visitStringLiteral(this);
}

std::string StringLiteral::getNodeName() const {
	return "StringLiteral(" + value + ")";
}

std::any NumberLiteral::accept(IRVisitor* visitor) {
	return visitor->visitNumberLiteral(this);
}

std::string NumberLiteral::getNodeName() const {
	return "NumberLiteral(" + value + ")";
}

std::any TupleLiteral::accept(IRVisitor* visitor) {
	return visitor->visitTupleLiteral(this);
}

std::string TupleLiteral::getNodeName() const {
	return "TupleLiteral";
}

std::string TupleLiteral::printChildren(const std::string& prefix) const {
	return printNodeVector(values, prefix);
}

} // namespace ir
