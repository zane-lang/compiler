#pragma once

#include <vector>
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
