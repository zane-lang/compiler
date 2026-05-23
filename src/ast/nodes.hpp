#pragma once
#include <memory>
#include <utility>
#include <variant>

namespace ast {

struct Node;
using NodePtr = std::unique_ptr<Node>;

struct IntNode {
	int value;
	IntNode(int v) : value(v) {}
};

struct ValueNode;

struct AddNode {
	std::unique_ptr<ValueNode> left;
	std::unique_ptr<ValueNode> right;
	explicit AddNode(std::unique_ptr<ValueNode> l, std::unique_ptr<ValueNode> r)
		: left(std::move(l)), right(std::move(r)) {}
};

struct ValueNode {
	std::variant<IntNode, AddNode> data;

	explicit ValueNode(IntNode t) : data(std::move(t)) {}
	explicit ValueNode(AddNode t) : data(std::move(t)) {}
};

struct Program {
	std::unique_ptr<ValueNode> valueNode;

	explicit Program(std::unique_ptr<ValueNode> t) : valueNode(std::move(t)) {};
};

} // namespace ast
