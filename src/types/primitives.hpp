#pragma once

#include <cstdint>
#include <string_view>
#include <charconv>

using i64 = std::int64_t;
using f64 = double;

inline bool try_build_i64(std::string_view s, i64& out) {
    auto [ptr, ec] = std::from_chars(s.data(), s.data() + s.size(), out);
    return ec == std::errc{} && ptr == s.data() + s.size();
}

inline bool try_build_f64(std::string_view s, f64& out) {
    auto [ptr, ec] = std::from_chars(s.data(), s.data() + s.size(), out);
    return ec == std::errc{} && ptr == s.data() + s.size();
}
