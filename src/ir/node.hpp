#pragma once

#include <string>
#include <vector>

namespace ir {

struct Node {
	std::string kind;
	std::string value;
	std::vector<Node*> children;

	Node(std::string nodeKind, std::string nodeValue = {})
		: kind(std::move(nodeKind)), value(std::move(nodeValue)) {}

	Node(const Node&) = delete;
	Node& operator=(const Node&) = delete;
	Node(Node&&) = default;
	Node& operator=(Node&&) = default;

	~Node() {
		for (Node* child : children) {
			delete child;
		}
	}

	std::string getNodeName() const {
		if (value.empty()) {
			return kind;
		}

		return kind + ": " + value;
	}

	std::string toString() const {
		return printTree("", true);
	}

	std::string printTree(const std::string& prefix, bool isLast) const {
		std::string result;
		std::string connector = isLast ? "└── " : "├── ";
		result += prefix + connector + getNodeName() + "\n";
		std::string childPrefix = prefix + (isLast ? "    " : "│   ");
		result += printChildren(childPrefix);
		return result;
	}

	std::string printChildren(const std::string& prefix) const {
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

} // namespace ir
