// nodes.hpp
#pragma once
#include <variant>
#include <memory>
#include <vector>
#include <string>

namespace ast {

// 1. Forward declare a concrete struct for recursive pointers
struct Node;
using NodePtr = std::unique_ptr<Node>;

// 2. Concrete AST types
struct IntNode   { int val; };
struct AddNode   { NodePtr lhs, rhs; };
struct CallNode  { std::string name; std::vector<NodePtr> args; };

// 3. Variant alias (different name to avoid clash)
using NodeVariant = std::variant<IntNode, AddNode, CallNode>;

// 4. Wrapper that ties the pointer and variant together
struct Node {
	NodeVariant data;
	template<typename T> explicit Node(T&& t) : data(std::forward<T>(t)) {}
};

struct Evaluator {
	int operator()(const IntNode& n) const { return n.val; }
	int operator()(const AddNode& n) const {
		return std::visit(*this, n.lhs->data) + std::visit(*this, n.rhs->data);
	}
	int operator()(const CallNode& n) const { return 0; }
};

} // namespace ast
