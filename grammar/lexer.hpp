#pragma once

#include <string>

namespace zane {
class Lexer {
public:
explicit Lexer(std::string source)
: source_(std::move(source)) {}

int next(void* semanticValue);

const char*& cursor() {
return cursor_;
}

const char*& marker() {
return marker_;
}

const char* limit() const {
return source_.data() + source_.size();
}

void reset() {
cursor_ = source_.data();
marker_ = source_.data();
}

private:
std::string source_;
const char* cursor_ = nullptr;
const char* marker_ = nullptr;
};

} // namespace zane
