#pragma once
#include <variant>

#include "nodes.hpp"

namespace ast {

struct Node {
	std::variant<
		std::monostate
		#define X(Name, Members) , Name
		#include "node_list.def"
		#undef X
	> data;
	
	// Default constructor (required by Bison)
	Node() : data(IntNode{0}) {}
	
	#define X(Name, Members) explicit Node(Name t) : data(std::move(t)) {}
	#include "node_list.def"
	#undef X
	
	// Enable copy semantics (required by Bison)
	Node(const Node& other) : data(other.data) {}
	Node& operator=(const Node& other) {
		data = other.data;
		return *this;
	}
	
	// Enable move semantics
	Node(Node&&) = default;
	Node& operator=(Node&&) = default;
};

inline AddNode::AddNode(std::unique_ptr<Node> l, std::unique_ptr<Node> r)
	: left(std::move(l)), right(std::move(r)) {}

inline AddNode::AddNode(const AddNode& other)
	: left(other.left ? std::make_unique<Node>(*other.left) : nullptr),
	  right(other.right ? std::make_unique<Node>(*other.right) : nullptr) {}

inline AddNode& AddNode::operator=(const AddNode& other) {
	left = other.left ? std::make_unique<Node>(*other.left) : nullptr;
	right = other.right ? std::make_unique<Node>(*other.right) : nullptr;
	return *this;
}

} // namespace ast
