#pragma once
#include <map>
#include <memory>
#include <string>
#include <utility>
#include <variant>
#include <vector>

namespace treegraph {

struct Node;

struct Table {
	std::map<std::string, std::unique_ptr<Node>> children;

	Table() = default;
	explicit Table(std::map<std::string, std::unique_ptr<Node>> children)
		: children(std::move(children)) {}

	Table& insert(std::string key, std::unique_ptr<Node> node) {
		children.insert_or_assign(std::move(key), std::move(node));
		return *this;
	}
};

struct List {
	std::vector<std::pair<std::string, std::unique_ptr<Node>>> children;

	List() = default;
	explicit List(std::vector<std::pair<std::string, std::unique_ptr<Node>>> children)
		: children(std::move(children)) {}

	List& push(std::string key, std::unique_ptr<Node> node) {
		children.emplace_back(std::move(key), std::move(node));
		return *this;
	}
};

struct Node {
	std::variant<Table, List, std::string> data;

	Node() = default;
	explicit Node(Table data) : data(std::move(data)) {}
	explicit Node(List data) : data(std::move(data)) {}
	explicit Node(std::string data) : data(std::move(data)) {}

	std::string render() const;
};

} // namespace treegraph
