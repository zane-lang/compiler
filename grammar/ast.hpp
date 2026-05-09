#pragma once

#include "../src/ir/node.hpp"

#include <iostream>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace zane {
	struct Node : ir::IRNode {
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

		std::any accept(ir::IRVisitor* visitor) override {
			return visitor->visitAstNode(this);
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

	inline std::string escapeJson(const std::string& text) {
		std::string escaped;
		escaped.reserve(text.size());

		for (char ch : text) {
			switch (ch) {
				case '\\':
					escaped += "\\\\";
					break;
				case '"':
					escaped += "\\\"";
					break;
				case '\n':
					escaped += "\\n";
					break;
				case '\r':
					escaped += "\\r";
					break;
				case '\t':
					escaped += "\\t";
					break;
				default:
					escaped += ch;
					break;
			}
		}

		return escaped;
	}

	inline void printNode(const Node* node, std::ostream& stream, int indent = 0) {
		const std::string prefix(indent, ' ');
		stream << prefix << "{\n";
		stream << prefix << "  \"kind\": \"" << escapeJson(node->kind) << "\"";

		if (!node->value.empty()) {
			stream << ",\n" << prefix << "  \"value\": \"" << escapeJson(node->value) << "\"";
		}

		if (!node->children.empty()) {
			stream << ",\n" << prefix << "  \"children\": [\n";
			for (std::size_t index = 0; index < node->children.size(); ++index) {
				printNode(node->children[index], stream, indent + 4);
				if (index + 1 < node->children.size()) {
					stream << ',';
				}
				stream << '\n';
			}
			stream << prefix << "  ]\n";
		} else {
			stream << ",\n" << prefix << "  \"children\": []\n";
		}

		stream << prefix << '}';
	}
} // namespace zane
