#pragma once

#include <variant>
#include <vector>
#include <iostream>
#include <sstream>
#include <string_view>
#include <type_traits>

// Helper for overloading lambdas
template<typename... Ts>
struct overloaded : Ts... {
	using Ts::operator()...;
};

template<typename... Ts>
overloaded(Ts...) -> overloaded<Ts...>;

// Helper function to load a variant at a specific index
template<std::size_t I = 0, typename... Types, typename Archive>
void loadVariantAt(std::size_t idx, std::variant<Types...>& var, Archive& ar) {
	if constexpr (I<sizeof...(Types)) {
		if (I == idx) {
			std::variant_alternative_t<I, std::variant<Types...>> val;
			ar(val);
			var = std::move(val);
		} else {
			loadVariantAt<I + 1>(idx, var, ar);
		}
	}
}

template<typename... Types>
struct Variant {
	std::variant<Types...> value;

	Variant() = default;
	Variant(std::variant<Types...> value)
	: value(std::move(value)) {}

	template<typename T,
	typename = std::enable_if_t<(std::is_same_v<std::decay_t<T>, Types> || ...)>>
	Variant(T&& val) : value(std::forward<T>(val)) {}

	template<typename T,
	typename = std::enable_if_t<(std::is_same_v<std::decay_t<T>, Types> || ...)>>
	Variant& operator=(T&& val) {
		value = std::forward<T>(val);
		return *this;
	}

	template<typename Callback>
	decltype(auto) visit(Callback&& callback) {
		return std::visit(std::forward<Callback>(callback), value);
	}

	template<typename Callback>
	decltype(auto) visit(Callback&& callback) const {
		return std::visit(std::forward<Callback>(callback), value);
	}

	template<typename... QueryTypes>
	bool is() const {
		return (std::holds_alternative<QueryTypes>(value) || ...);
	}

	template<typename T>
	T* getIf() {
		return std::get_if<T>(&value);
	}

	template<typename T>
	const T* getIf() const {
		return std::get_if<T>(&value);
	}

	template<typename... Callbacks>
	decltype(auto) match(Callbacks&&... callbacks) {
		return std::visit(
			overloaded{
				std::forward<Callbacks>(callbacks)...,
				[](auto&&) {}
			},
			value
		);
	}

	template<typename... Callbacks>
	decltype(auto) match(Callbacks&&... callbacks) const {
		return std::visit(
			overloaded{
				std::forward<Callbacks>(callbacks)...,
				[](auto&&) {}
			},
			value
		);
	}

	template<typename Archive>
	void save(Archive& ar) const {
		ar(value.index());
		std::visit([&ar](const auto& v) { ar(v); }, value);
	}

	template<typename Archive>
	void load(Archive& ar) {
		std::size_t idx;
		ar(idx);
		loadVariantAt<0>(idx, value, ar);
	}

	bool operator==(const Variant&) const = default;
};

template<template<typename> class Wrapper, typename... Types>
struct WrappingVariant {
	std::variant<Wrapper<Types>...> value;

	WrappingVariant() = default;
	WrappingVariant(std::variant<Wrapper<Types>...> value)
	: value(std::move(value)) {}

	template<typename T,
	typename = std::enable_if_t<(std::is_same_v<std::decay_t<T>, Wrapper<Types>> || ...)>>
	WrappingVariant(T&& val) : value(std::forward<T>(val)) {}

	template<typename T,
	typename = std::enable_if_t<(std::is_same_v<std::decay_t<T>, Wrapper<Types>> || ...)>>
	WrappingVariant& operator=(T&& val) {
		value = std::forward<T>(val);
		return *this;
	}


	template<typename Callback>
	decltype(auto) visit(Callback&& callback) {
		return std::visit(std::forward<Callback>(callback), value);
	}

	template<typename Callback>
	decltype(auto) visit(Callback&& callback) const {
		return std::visit(std::forward<Callback>(callback), value);
	}

	template<typename... Callbacks>
	decltype(auto) match(Callbacks&&... callbacks) {
		return std::visit(
			overloaded{
				std::forward<Callbacks>(callbacks)...,
				[](auto&&) {}
			},
			value
		);
	}

	template<typename... Callbacks>
	decltype(auto) match(Callbacks&&... callbacks) const {
		return std::visit(
			overloaded{
				std::forward<Callbacks>(callbacks)...,
				[](auto&&) {}
			},
			value
		);
	}

	template<typename Archive>
	void save(Archive& ar) const {
		ar(value.index());
		std::visit([&ar](const auto& v) { ar(v); }, value);
	}

	template<typename Archive>
	void load(Archive& ar) {
		std::size_t idx;
		ar(idx);
		loadVariantAt<0>(idx, value, ar);
	}

	bool operator==(const WrappingVariant&) const = default;
};

#define ZANE_NODE_KIND_LIST(X) \
	X(abort_stmt, "abort_stmt") \
	X(abort_type, "abort_type") \
	X(assign_init, "assign_init") \
	X(assignment_stmt, "assignment_stmt") \
	X(binary_expr, "binary_expr") \
	X(block, "block") \
	X(block_body, "block_body") \
	X(bool_literal, "bool_literal") \
	X(call_expr, "call_expr") \
	X(call_init, "call_init") \
	X(callable_name, "callable_name") \
	X(class_decl, "class_decl") \
	X(class_kind, "class_kind") \
	X(constructor_decl, "constructor_decl") \
	X(ctor_field_entry, "ctor_field_entry") \
	X(elif_clause, "elif_clause") \
	X(else_clause, "else_clause") \
	X(expr_body, "expr_body") \
	X(expression_stmt, "expression_stmt") \
	X(fallback_expr, "fallback_expr") \
	X(field_arg, "field_arg") \
	X(field_constructor_decl, "field_constructor_decl") \
	X(field_ctor_expr, "field_ctor_expr") \
	X(field_decl, "field_decl") \
	X(field_init, "field_init") \
	X(function_decl, "function_decl") \
	X(generic_args, "generic_args") \
	X(group_expr, "group_expr") \
	X(guard_stmt, "guard_stmt") \
	X(handler_clause, "handler_clause") \
	X(handler_expr, "handler_expr") \
	X(if_stmt, "if_stmt") \
	X(import_decl, "import_decl") \
	X(init_expr, "init_expr") \
	X(init_expr_item, "init_expr_item") \
	X(init_item, "init_item") \
	X(intrinsic_name, "intrinsic_name") \
	X(intrinsic_type, "intrinsic_type") \
	X(list_expr, "list_expr") \
	X(member_expr, "member_expr") \
	X(method_call_expr, "method_call_expr") \
	X(mut, "mut") \
	X(name, "name") \
	X(named_arg, "named_arg") \
	X(named_type, "named_type") \
	X(namespace_name, "namespace") \
	X(int_literal, "int_literal") \
	X(float_literal, "float_literal") \
	X(operator_name, "operator_name") \
	X(package_decl, "package_decl") \
	X(param_decl, "param_decl") \
	X(program, "program") \
	X(qualified_name, "qualified_name") \
	X(qualified_type, "qualified_type") \
	X(ref, "ref") \
	X(ref_type, "ref_type") \
	X(resolve_stmt, "resolve_stmt") \
	X(return_stmt, "return_stmt") \
	X(return_type, "return_type") \
	X(segment, "segment") \
	X(storage_decl, "storage_decl") \
	X(string_literal, "string_literal") \
	X(struct_decl, "struct_decl") \
	X(subscript_expr, "subscript_expr") \
	X(symbol_decl, "symbol_decl") \
	X(type_name, "type_name") \
	X(type_param, "type_param") \
	X(unary_expr, "unary_expr")

namespace ir::node_kind {

#define ZANE_DECLARE_NODE_KIND(kind, name) \
	struct kind { \
		constexpr bool operator==(const kind&) const = default; \
	};
ZANE_NODE_KIND_LIST(ZANE_DECLARE_NODE_KIND)
#undef ZANE_DECLARE_NODE_KIND

} // namespace ir::node_kind

namespace ir {

using NodeKind = Variant<
	node_kind::abort_stmt,
	node_kind::abort_type,
	node_kind::assign_init,
	node_kind::assignment_stmt,
	node_kind::binary_expr,
	node_kind::block,
	node_kind::block_body,
	node_kind::bool_literal,
	node_kind::call_expr,
	node_kind::call_init,
	node_kind::callable_name,
	node_kind::class_decl,
	node_kind::class_kind,
	node_kind::constructor_decl,
	node_kind::ctor_field_entry,
	node_kind::elif_clause,
	node_kind::else_clause,
	node_kind::expr_body,
	node_kind::expression_stmt,
	node_kind::fallback_expr,
	node_kind::field_arg,
	node_kind::field_constructor_decl,
	node_kind::field_ctor_expr,
	node_kind::field_decl,
	node_kind::field_init,
	node_kind::function_decl,
	node_kind::generic_args,
	node_kind::group_expr,
	node_kind::guard_stmt,
	node_kind::handler_clause,
	node_kind::handler_expr,
	node_kind::if_stmt,
	node_kind::import_decl,
	node_kind::init_expr,
	node_kind::init_expr_item,
	node_kind::init_item,
	node_kind::intrinsic_name,
	node_kind::intrinsic_type,
	node_kind::list_expr,
	node_kind::member_expr,
	node_kind::method_call_expr,
	node_kind::mut,
	node_kind::name,
	node_kind::named_arg,
	node_kind::named_type,
	node_kind::namespace_name,
	node_kind::int_literal,
	node_kind::float_literal,
	node_kind::operator_name,
	node_kind::package_decl,
	node_kind::param_decl,
	node_kind::program,
	node_kind::qualified_name,
	node_kind::qualified_type,
	node_kind::ref,
	node_kind::ref_type,
	node_kind::resolve_stmt,
	node_kind::return_stmt,
	node_kind::return_type,
	node_kind::segment,
	node_kind::storage_decl,
	node_kind::string_literal,
	node_kind::struct_decl,
	node_kind::subscript_expr,
	node_kind::symbol_decl,
	node_kind::type_name,
	node_kind::type_param,
	node_kind::unary_expr
>;

template<typename Kind>
struct NodeKindName;

#define ZANE_DEFINE_NODE_KIND_NAME(kind, name) \
	template<> \
	struct NodeKindName<node_kind::kind> { \
		static constexpr std::string_view value = name; \
	};
ZANE_NODE_KIND_LIST(ZANE_DEFINE_NODE_KIND_NAME)
#undef ZANE_DEFINE_NODE_KIND_NAME

inline std::string_view nodeKindName(const NodeKind& kind) {
	return kind.visit([](const auto& currentKind) -> std::string_view {
		return NodeKindName<std::decay_t<decltype(currentKind)>>::value;
	});
}

} // namespace ir

#undef ZANE_NODE_KIND_LIST

template<typename T>
class Stack {
	std::vector<T> stack;
public:
	Stack() = default;
	void push(T element) { stack.push_back(element); }
	bool empty() const { return stack.empty(); }
	T& top() { return stack.back(); }
	T top() const { return stack.back(); }
	T pop() {
		if (stack.empty()) return {};
		auto value = stack.back();
		stack.pop_back();
		return value;
	}
	auto rbegin() { return stack.rbegin(); }
	auto rend()   { return stack.rend(); }
	auto begin()  { return stack.begin(); }
	auto end()    { return stack.end(); }
};
