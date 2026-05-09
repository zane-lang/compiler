#pragma once

#include <any>
#include <memory>
#include <string>
#include <vector>

namespace ir {

struct IRNode;
struct Node;
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
	virtual std::any visitNode(Node*) { return {}; }
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

struct Node : IRNode {
	std::string kind;
	std::string value;
	std::vector<Node*> children;

	Node(std::string nodeKind, std::string nodeValue = {})
		: kind(std::move(nodeKind)), value(std::move(nodeValue)) {}

	~Node() override {
		for (Node* child : children) {
			delete child;
		}
	}

	std::any accept(IRVisitor* visitor) override {
		return visitor->visitNode(this);
	}

	std::string getNodeName() const override {
		if (value.empty()) {
			return kind;
		}

		return kind + ": " + value;
	}

	std::string printChildren(const std::string& prefix) const override {
		std::string result;
		for (std::size_t index = 0; index < children.size(); ++index) {
			if (children[index] == nullptr) {
				continue;
			}

			result += children[index]->printTree(prefix, index + 1 == children.size());
		}
		return result;
	}
};

using NodeList = std::vector<Node*>;

inline Node* makeNode(std::string kind, std::string value = {}) {
	return new Node(std::move(kind), std::move(value));
}

inline NodeList* makeList() {
	return new NodeList();
}

inline void push(NodeList* list, Node* node) {
	if (list != nullptr && node != nullptr) {
		list->push_back(node);
	}
}

inline Node* adopt(Node* parent, Node* child) {
	if (parent != nullptr && child != nullptr) {
		parent->children.push_back(child);
	}
	return parent;
}

inline Node* adoptValue(Node* parent, const std::string& kind, const std::string& value) {
	if (parent != nullptr) {
		parent->children.push_back(makeNode(kind, value));
	}
	return parent;
}

inline Node* adoptList(Node* parent, NodeList* list) {
	if (parent != nullptr && list != nullptr) {
		for (Node* child : *list) {
			if (child != nullptr) {
				parent->children.push_back(child);
			}
		}
	}
	delete list;
	return parent;
}

inline std::any IRVisitor::visit(IRNode* node) {
	if (node) {
		return node->accept(this);
	}
	return {};
}

} // namespace ir
