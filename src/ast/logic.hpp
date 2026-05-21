#pragma once
#include <memory>
#include <variant>

namespace ast {

// Integer literal node
struct IntNode {
    int value;
    IntNode(int v) : value(v) {}
    IntNode(const IntNode&) = default;
    IntNode& operator=(const IntNode&) = default;
};

// Addition node (left + right)
struct AddNode {
    std::unique_ptr<struct Node> left;
    std::unique_ptr<struct Node> right;
    AddNode(std::unique_ptr<struct Node> l, std::unique_ptr<struct Node> r) 
        : left(std::move(l)), right(std::move(r)) {}
    AddNode(const AddNode& other) 
        : left(other.left ? std::make_unique<Node>(*other.left) : nullptr),
          right(other.right ? std::make_unique<Node>(*other.right) : nullptr) {}
    AddNode& operator=(const AddNode& other) {
        left = other.left ? std::make_unique<Node>(*other.left) : nullptr;
        right = other.right ? std::make_unique<Node>(*other.right) : nullptr;
        return *this;
    }
};

// Node is a variant of all possible AST nodes
struct Node {
    std::variant<IntNode, AddNode> data;
    
    // Default constructor (required by Bison)
    Node() : data(IntNode{0}) {}
    
    // Constructor for IntNode
    explicit Node(IntNode t) : data(t) {}
    
    // Constructor for AddNode
    explicit Node(AddNode t) : data(t) {}
    
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

} // namespace ast