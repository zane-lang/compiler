#pragma once

#include "ast/nodes.hpp"
#include <string>
#include <variant>
#include <stdexcept>

namespace ast::evaluators {

struct ToString {
    std::string operator()(const nodes::Program& program) const {
		// NOTE: can only visit variant types
        return std::visit(*this, program.valueNode->data);
    }

    std::string operator()(const nodes::ValueNode& node) const {
        return std::visit(*this, node.data);
    }

    std::string operator()(const nodes::IntNode& n) const {
        return std::to_string(n.value);
    }

    std::string operator()(const nodes::AddNode& n) const {
		// NOTE: can only visit variant types,which is why we get data directly
        std::string l = std::visit(*this, n.left->data);
        std::string r = std::visit(*this, n.right->data);
        return "(" + l + " + " + r + ")";
    }
};

} // namespace evaluators
