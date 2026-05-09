#pragma once

#include <any>
#include <memory>
#include <string>
#include <vector>

namespace zane {
	struct Node;
}

namespace ir {

struct IRNode;
struct FuncDef;
struct VarDef;
struct GlobalScope;
struct Scope;
struct FuncCall;
struct StringLiteral;
struct FuncType;
struct ReturnStatement;
	struct Type;
	struct ValueSymbol;
	struct TypeSymbol;
	struct Lambda;

class IRVisitor {
public:
	virtual ~IRVisitor() = default;
	virtual std::any visit(IRNode* node);

	virtual std::any visitFuncDef(FuncDef*) { return {}; }
	virtual std::any visitGlobalScope(GlobalScope*) { return {}; }
	virtual std::any visitScope(Scope*) { return {}; }
	virtual std::any visitFuncCall(FuncCall*) { return {}; }
	virtual std::any visitStringLiteral(StringLiteral*) { return {}; }
	virtual std::any visitType(Type*) { return {}; }
	virtual std::any visitFuncType(FuncType*) { return {}; }
	virtual std::any visitVarDef(VarDef*) { return {}; }
	virtual std::any visitReturnStatement(ReturnStatement*) { return {}; }
	virtual std::any visitValueSymbol(ValueSymbol*) { return {}; }
	virtual std::any visitTypeSymbol(TypeSymbol*) { return {}; }
	virtual std::any visitLambda(Lambda*) { return {}; }
	virtual std::any visitAstNode(zane::Node*) { return {}; }
};

struct IRNode {
	virtual ~IRNode() = default;
	virtual std::string getNodeName() const = 0;
	virtual std::any accept(IRVisitor* visitor) = 0;
	virtual std::string toString() const {
		return printTree("", true);
	}

	virtual std::string printTree(const std::string& prefix, bool isLast) const {
		std::string result;
		std::string connector = isLast ? "└── " : "├── ";
		result += prefix + connector + getNodeName() + "\n";
		std::string childPrefix = prefix + (isLast ? "    " : "│   ");
		result += printChildren(childPrefix);
		return result;
	}

	virtual std::string printChildren(const std::string&) const {
		return "";
	}

protected:
	std::string printNodeVector(const std::vector<std::shared_ptr<IRNode>>& nodes, const std::string& prefix) const {
		std::string result;
		for (size_t i = 0; i < nodes.size(); ++i) {
			bool last = (i == nodes.size() - 1);
			if (nodes[i]) {
				result += nodes[i]->printTree(prefix, last);
			}
		}
		return result;
	}
};

inline std::any IRVisitor::visit(IRNode* node) {
	if (node) {
		return node->accept(this);
	}
	return {};
}

} // namespace ir
