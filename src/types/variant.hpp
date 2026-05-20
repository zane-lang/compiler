#pragma once

#include <variant>
#include <vector>
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
	if constexpr (I < sizeof...(Types)) {
		if (I == idx) {
			std::variant_alternative_t<I, std::variant<Types...>> val;
			ar(val);
			var = std::move(val);
		} else {
			loadVariantAt<I + 1>(idx, var, ar);
		}
	}
}

// Returns invoke_result_t<F, Arg> if invocable, otherwise void.
// Used by match() to probe what return type each callback produces.
template<typename F, typename Arg, typename = void>
struct safe_invoke_result { using type = void; };
template<typename F, typename Arg>
struct safe_invoke_result<F, Arg, std::void_t<std::invoke_result_t<F, Arg>>> {
	using type = std::invoke_result_t<F, Arg>;
};

// Walks a type list and picks the first non-void type, or Default if all are void.
// Lets match() find the real return type even when some alternatives are unhandled.
template<typename Default, typename... Ts>
struct first_non_void_or { using type = Default; };
template<typename Default, typename T, typename... Rest>
struct first_non_void_or<Default, T, Rest...> {
	using type = std::conditional_t<!std::is_void_v<T>, T,
		typename first_non_void_or<Default, Rest...>::type>;
};

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

	// visit: accepts a single callable (use match for multiple lambdas)
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

	// match: handles a subset of types; unhandled alternatives return R{} (or void).
	// The catch-all return type is deduced from the provided callbacks so that
	// returning a value (e.g. std::string) works without an explicit default case.
	template<typename... Callbacks>
	decltype(auto) match(Callbacks&&... callbacks) {
		using Visitor = overloaded<std::decay_t<Callbacks>...>;
		using R = typename first_non_void_or<void,
			typename safe_invoke_result<Visitor, Types&>::type...
		>::type;

		if constexpr (std::is_void_v<R>) {
			return std::visit(
				overloaded{ std::forward<Callbacks>(callbacks)..., [](auto&&) {} },
				value
			);
		} else {
			return std::visit(
				overloaded{ std::forward<Callbacks>(callbacks)..., [](auto&&) -> R { return R{}; } },
				value
			);
		}
	}

	template<typename... Callbacks>
	decltype(auto) match(Callbacks&&... callbacks) const {
		using Visitor = overloaded<std::decay_t<Callbacks>...>;
		using R = typename first_non_void_or<void,
			typename safe_invoke_result<Visitor, const Types&>::type...
		>::type;

		if constexpr (std::is_void_v<R>) {
			return std::visit(
				overloaded{ std::forward<Callbacks>(callbacks)..., [](auto&&) {} },
				value
			);
		} else {
			return std::visit(
				overloaded{ std::forward<Callbacks>(callbacks)..., [](auto&&) -> R { return R{}; } },
				value
			);
		}
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

	// visit: accepts a single callable (use match for multiple lambdas)
	template<typename Callback>
	decltype(auto) visit(Callback&& callback) {
		return std::visit(std::forward<Callback>(callback), value);
	}

	template<typename Callback>
	decltype(auto) visit(Callback&& callback) const {
		return std::visit(std::forward<Callback>(callback), value);
	}

	// match: handles a subset of types; unhandled alternatives return R{} (or void).
	template<typename... Callbacks>
	decltype(auto) match(Callbacks&&... callbacks) {
		using Visitor = overloaded<std::decay_t<Callbacks>...>;
		using R = typename first_non_void_or<void,
			typename safe_invoke_result<Visitor, Wrapper<Types>&>::type...
		>::type;

		if constexpr (std::is_void_v<R>) {
			return std::visit(
				overloaded{ std::forward<Callbacks>(callbacks)..., [](auto&&) {} },
				value
			);
		} else {
			return std::visit(
				overloaded{ std::forward<Callbacks>(callbacks)..., [](auto&&) -> R { return R{}; } },
				value
			);
		}
	}

	template<typename... Callbacks>
	decltype(auto) match(Callbacks&&... callbacks) const {
		using Visitor = overloaded<std::decay_t<Callbacks>...>;
		using R = typename first_non_void_or<void,
			typename safe_invoke_result<Visitor, const Wrapper<Types>&>::type...
		>::type;

		if constexpr (std::is_void_v<R>) {
			return std::visit(
				overloaded{ std::forward<Callbacks>(callbacks)..., [](auto&&) {} },
				value
			);
		} else {
			return std::visit(
				overloaded{ std::forward<Callbacks>(callbacks)..., [](auto&&) -> R { return R{}; } },
				value
			);
		}
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
