#include "request_json.hpp"

#include <cctype>
#include <cstdint>
#include <limits>
#include <string>

namespace amd_mobile_power {

std::optional<int> ExtractJsonInt(std::string_view json, std::string_view key) {
    const std::string needle = "\"" + std::string(key) + "\"";
    const std::size_t key_position = json.find(needle);
    if (key_position == std::string_view::npos) {
        return std::nullopt;
    }
    const std::size_t colon_position = json.find(':', key_position + needle.size());
    if (colon_position == std::string_view::npos) {
        return std::nullopt;
    }

    std::size_t position = colon_position + 1;
    while (position < json.size() &&
        std::isspace(static_cast<unsigned char>(json[position]))) {
        ++position;
    }
    if (position >= json.size()) {
        return std::nullopt;
    }

    const bool negative = json[position] == '-';
    if (negative) {
        ++position;
    }
    if (position >= json.size() ||
        !std::isdigit(static_cast<unsigned char>(json[position]))) {
        return std::nullopt;
    }

    // Accumulate against a magnitude bound instead of int arithmetic so
    // hostile digit strings cannot trigger signed overflow. Leading zeros
    // stay valid because the bound applies to the value, not the digit count.
    const std::int64_t maximum =
        static_cast<std::int64_t>(std::numeric_limits<int>::max()) +
        (negative ? 1 : 0);
    std::int64_t value = 0;
    while (position < json.size() &&
        std::isdigit(static_cast<unsigned char>(json[position]))) {
        const int digit = json[position] - '0';
        if (value > (maximum - digit) / 10) {
            return std::nullopt;
        }
        value = value * 10 + digit;
        ++position;
    }
    return static_cast<int>(negative ? -value : value);
}

}  // namespace amd_mobile_power
