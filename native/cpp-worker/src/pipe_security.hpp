#pragma once

#include <windows.h>

#include <array>
#include <vector>

namespace amd_mobile_power {

// RAII security descriptor for the worker pipe: the current process user gets
// GENERIC_READ | GENERIC_WRITE | SYNCHRONIZE and SYSTEM keeps GENERIC_ALL.
// Every buffer stays alive until the object is destroyed; CreateNamedPipeW
// copies the descriptor during the call.
class PipeSecurityDescriptor {
public:
    PipeSecurityDescriptor() = default;

    PipeSecurityDescriptor(const PipeSecurityDescriptor&) = delete;
    PipeSecurityDescriptor& operator=(const PipeSecurityDescriptor&) = delete;

    bool Initialize();
    SECURITY_ATTRIBUTES* attributes();

private:
    std::vector<unsigned char> token_user_;
    std::array<unsigned char, SECURITY_MAX_SID_SIZE> system_sid_{};
    std::vector<unsigned char> acl_;
    SECURITY_DESCRIPTOR descriptor_{};
    SECURITY_ATTRIBUTES attributes_{};
    bool initialized_ = false;
};

}  // namespace amd_mobile_power
