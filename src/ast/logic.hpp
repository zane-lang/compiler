#pragma once
#include "nodes.hpp"
#include <variant>
namespace ast {
    #define X(Name, Body) Name,
    using NodeVariant = std::variant<
        #include "node_list.def"
        std::monostate
    >;
    #undef X

    struct Node {
        NodeVariant data;
        template<typename T> explicit Node(T&& t) : data(std::forward<T>(t)) {}
    };
}
