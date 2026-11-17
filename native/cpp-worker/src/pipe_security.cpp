#include "pipe_security.hpp"

namespace amd_mobile_power {

bool PipeSecurityDescriptor::Initialize() {
    if (initialized_) {
        return true;
    }

    DWORD token_user_size = 0;
    GetTokenInformation(
        GetCurrentProcessToken(), TokenUser, nullptr, 0, &token_user_size);
    if (GetLastError() != ERROR_INSUFFICIENT_BUFFER || token_user_size == 0) {
        return false;
    }
    token_user_.resize(token_user_size);
    if (!GetTokenInformation(
            GetCurrentProcessToken(),
            TokenUser,
            token_user_.data(),
            token_user_size,
            &token_user_size)) {
        return false;
    }
    const auto* token_user =
        reinterpret_cast<const TOKEN_USER*>(token_user_.data());
    if (!IsValidSid(token_user->User.Sid)) {
        return false;
    }

    DWORD system_sid_size = static_cast<DWORD>(system_sid_.size());
    if (!CreateWellKnownSid(
            WinLocalSystemSid, nullptr, system_sid_.data(), &system_sid_size)) {
        return false;
    }

    const DWORD user_sid_size = GetLengthSid(token_user->User.Sid);
    const DWORD ace_overhead =
        static_cast<DWORD>(sizeof(ACCESS_ALLOWED_ACE) - sizeof(DWORD));
    const DWORD acl_size = static_cast<DWORD>(sizeof(ACL)) +
        ace_overhead + user_sid_size + ace_overhead + system_sid_size;
    acl_.resize(acl_size);
    PACL acl = reinterpret_cast<PACL>(acl_.data());
    if (!InitializeAcl(acl, acl_size, ACL_REVISION)) {
        return false;
    }
    // Least privilege for the interactive user: GUI, probe, and script clients
    // only open the pipe for read/write. SYSTEM retains full control.
    constexpr ACCESS_MASK kUserPipeAccess =
        GENERIC_READ | GENERIC_WRITE | SYNCHRONIZE;
    if (!AddAccessAllowedAceEx(
            acl, ACL_REVISION, 0, kUserPipeAccess, token_user->User.Sid) ||
        !AddAccessAllowedAceEx(
            acl, ACL_REVISION, 0, GENERIC_ALL, system_sid_.data())) {
        return false;
    }

    if (!InitializeSecurityDescriptor(
            &descriptor_, SECURITY_DESCRIPTOR_REVISION)) {
        return false;
    }
    if (!SetSecurityDescriptorDacl(&descriptor_, TRUE, acl, FALSE)) {
        return false;
    }

    attributes_.nLength = static_cast<DWORD>(sizeof(attributes_));
    attributes_.lpSecurityDescriptor = &descriptor_;
    attributes_.bInheritHandle = FALSE;
    initialized_ = true;
    return true;
}

SECURITY_ATTRIBUTES* PipeSecurityDescriptor::attributes() {
    return initialized_ ? &attributes_ : nullptr;
}

}  // namespace amd_mobile_power
