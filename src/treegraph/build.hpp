#pragma once

#include "treegraph/structure.hpp"
#include <memory>
#include <string>
#include <utility>

namespace treegraph {

inline std::unique_ptr<Node> ptr(Node node) {
	return std::make_unique<Node>(std::move(node));
}

inline std::unique_ptr<Node> string(std::string value) {
	return ptr(Node{std::move(value)});
}

inline std::unique_ptr<Node> table(Table table) {
	return ptr(Node{std::move(table)});
}

inline std::unique_ptr<Node> list(List list) {
	return ptr(Node{std::move(list)});
}

} // namespace treegraph
