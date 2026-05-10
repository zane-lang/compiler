#pragma once

#include "../src/ir/node.hpp"

#include <iostream>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace zane {
	using Node = ir::Node;
	using NodeList = ir::NodeList;
	using ir::adopt;
	using ir::adoptList;
	using ir::adoptValue;
	using ir::makeList;
	using ir::makeNode;
	using ir::push;

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
		stream << prefix << "  \"kind\": \""
			   << escapeJson(std::string(ir::nodeKindName(node->kind))) << "\"";

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
