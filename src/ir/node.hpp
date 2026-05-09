#pragma once

#include "visitor.hpp"

#include <memory>
#include <string>
#include <vector>

namespace ir {

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

	Node(const Node&) = delete;
	Node& operator=(const Node&) = delete;
	Node(Node&&) = default;
	Node& operator=(Node&&) = default;

	~Node() override {
		for (Node* child : children) {
			delete child;
		}
	}

	std::any accept(IRVisitor* visitor) override;

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

inline std::any Node::accept(IRVisitor* visitor) {
	return visitor->visitNode(this);
}

} // namespace ir
