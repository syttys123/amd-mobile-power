#pragma once

#include <optional>
#include <string_view>

namespace amd_mobile_power {

// Extracts a base-10 integer field from a JSON request. Returns nullopt when
// the key is missing, the value is not an integer, or its magnitude exceeds
// the signed 32-bit range.
std::optional<int> ExtractJsonInt(std::string_view json, std::string_view key);

}  // namespace amd_mobile_power
