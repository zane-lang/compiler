#pragma once

#include "treegraph/structure.hpp"
#include <sstream>
#include <string>
#include <vector>

namespace treegraph {

namespace detail {

inline std::vector<std::string> splitLines(const std::string& text) {
	std::istringstream ss(text);
	std::vector<std::string> lines;
	std::string line;
	while (std::getline(ss, line))
		lines.push_back(line);
	return lines;
}

// Indents every line after the first with `prefix`.
inline std::string indent(const std::string& text, const std::string& prefix) {
	const auto lines = splitLines(text);
	if (lines.empty()) return {};
	std::string result = lines.front();
	for (std::size_t i = 1; i < lines.size(); ++i)
		result += "\n" + prefix + lines[i];
	return result;
}

// Renders a single named branch: "label: firstLine\n  continuation..."
inline std::string branch(const std::string& label, const std::string& subtree) {
	const auto lines = splitLines(subtree);
	if (lines.empty()) return label;
	std::string result = label + ": " + lines.front();
	for (std::size_t i = 1; i < lines.size(); ++i)
		result += "\n  " + lines[i];
	return result;
}

// Renders a labelled node with ├──/└── children.
inline std::string node(const std::string& label, const std::vector<std::string>& children) {
	if (children.empty()) return label;
	std::string result = label;
	for (std::size_t i = 0; i < children.size(); ++i) {
		const bool last = (i + 1 == children.size());
		result += "\n";
		result += last ? "└── " : "├── ";
		result += indent(children[i], last ? "    " : "│   ");
	}
	return result;
}

} // namespace detail

struct Evaluator {
	std::string render(const Node& node) const {
		return std::visit([&](const auto& data) {
			return (*this)(data);
		}, node.data);
	}

	std::string render(const std::string& key, const Node& node) const {
		return std::visit([&](const auto& data) {
			return renderWith(key, data);
		}, node.data);
	}

	std::string operator()(const Node& node) const { return render(node); }

	std::string operator()(const std::string& key, const Node& node) const { return render(key, node); }

	std::string operator()(const Table& table) const {
		std::vector<std::string> rows;
		for (const auto& [key, child] : table.children)
			appendRenderedChild(rows, key, *child);
		return joinLines(rows);
	}

	std::string operator()(const List& list) const {
		std::vector<std::string> items;
		for (const auto& [key, child] : list.children)
			items.push_back(render(key, *child));
		return joinLines(items);
	}

	std::string operator()(const std::string& str) const { return str; }

private:
	void appendRenderedChild(std::vector<std::string>& rows, const std::string& key, const Node& node) const {
		if (const auto* list = std::get_if<List>(&node.data)) {
			const auto items = renderListEntries(key, *list);
			rows.insert(rows.end(), items.begin(), items.end());
			return;
		}
		rows.push_back(render(key, node));
	}

	std::vector<std::string> renderListEntries(const std::string& key, const List& list) const {
		std::vector<std::string> children;
		for (std::size_t i = 0; i < list.children.size(); ++i) {
			const auto& [itemKey, child] = list.children[i];
			children.push_back(render(key + "[" + std::to_string(i) + "]", itemKey, *child));
		}
		return children;
	}

	std::string render(const std::string& indexedKey, const std::string& itemKey, const Node& node) const {
		return std::visit([&](const auto& data) {
			return renderIndexed(indexedKey, itemKey, data);
		}, node.data);
	}

	std::string renderWith(const std::string& key, const std::string& value) const {
		return value.empty() ? key : key + ": " + value;
	}

	std::string renderWith(const std::string& key, const Table& table) const {
		std::vector<std::string> children;
		for (const auto& [childKey, child] : table.children)
			appendRenderedChild(children, childKey, *child);
		return detail::node(key, children);
	}

	std::string renderWith(const std::string& key, const List& list) const {
		return detail::node(key, renderListEntries(key, list));
	}

	std::string renderIndexed(const std::string& indexedKey, const std::string& itemKey, const std::string& value) const {
		if (itemKey.empty())
			return value.empty() ? indexedKey : indexedKey + ": " + value;
		const auto label = value.empty() ? itemKey : itemKey + ": " + value;
		return detail::node(indexedKey, {label});
	}

	std::string renderIndexed(const std::string& indexedKey, const std::string& itemKey, const Table& table) const {
		std::vector<std::string> children;
		for (const auto& [childKey, child] : table.children)
			appendRenderedChild(children, childKey, *child);
		if (itemKey.empty())
			return detail::node(indexedKey, children);
		return detail::node(indexedKey, {detail::node(itemKey, children)});
	}

	std::string renderIndexed(const std::string& indexedKey, const std::string& itemKey, const List& list) const {
		if (itemKey.empty())
			return detail::node(indexedKey, renderListEntries(indexedKey, list));
		return detail::node(indexedKey, {detail::node(itemKey, renderListEntries(indexedKey, list))});
	}

	static std::string joinLines(const std::vector<std::string>& parts) {
		std::string result;
		for (std::size_t i = 0; i < parts.size(); ++i) {
			if (i > 0) result += "\n";
			result += parts[i];
		}
		return result;
	}
};

} // namespace treegraph
