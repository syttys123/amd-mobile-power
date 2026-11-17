#define NOMINMAX

#include "../src/pipe_security.hpp"
#include "../src/power_limit_policy.hpp"
#include "../src/request_json.hpp"
#include "../src/ryzen_hardware.hpp"

#include <cmath>
#include <cstdint>
#include <iostream>
#include <limits>
#include <optional>
#include <string>
#include <string_view>

namespace {

int failures = 0;

void Check(bool condition, const char* name) {
    if (!condition) {
        std::cerr << "FAIL: " << name << "\n";
        ++failures;
    }
}

// Fake SMU state shared by the stub driver exports below. No real driver or
// hardware is touched; RyzenHardware only calls these through its pointers.
struct FakeSmuState {
    double stapm_limit = 30.0;
    double fast_limit = 35.0;
    double slow_limit = 28.0;
    double stapm_value = 25.0;
    double fast_value = 30.0;
    double slow_value = 27.0;
    double tctl_value = 55.0;
    double tctl_limit = 95.0;
    int set_result = 0;
    bool clamp_stapm_on_write = false;
    bool clamp_fast_on_write = false;
    bool stapm_value_nan = false;
    bool fast_limit_inf = false;
    int stapm_writes = 0;
    int fast_writes = 0;
    int slow_writes = 0;
};

FakeSmuState g_smu;

int __stdcall FakeRefreshTable(void*) { return 0; }

int __stdcall FakeSetStapm(void*, std::uint32_t milliwatts) {
    ++g_smu.stapm_writes;
    if (g_smu.set_result != 0) { return g_smu.set_result; }
    g_smu.stapm_limit = g_smu.clamp_stapm_on_write
        ? 20.0
        : static_cast<double>(milliwatts) / 1000.0;
    return 0;
}

int __stdcall FakeSetFast(void*, std::uint32_t milliwatts) {
    ++g_smu.fast_writes;
    if (g_smu.set_result != 0) { return g_smu.set_result; }
    g_smu.fast_limit = g_smu.clamp_fast_on_write
        ? 20.0
        : static_cast<double>(milliwatts) / 1000.0;
    return 0;
}

int __stdcall FakeSetSlow(void*, std::uint32_t milliwatts) {
    ++g_smu.slow_writes;
    if (g_smu.set_result != 0) { return g_smu.set_result; }
    g_smu.slow_limit = static_cast<double>(milliwatts) / 1000.0;
    return 0;
}

float __stdcall FakeGetStapmLimit(void*) {
    return static_cast<float>(g_smu.stapm_limit);
}
float __stdcall FakeGetFastLimit(void*) {
    return g_smu.fast_limit_inf
        ? std::numeric_limits<float>::infinity()
        : static_cast<float>(g_smu.fast_limit);
}
float __stdcall FakeGetSlowLimit(void*) {
    return static_cast<float>(g_smu.slow_limit);
}
float __stdcall FakeGetStapmValue(void*) {
    return g_smu.stapm_value_nan
        ? std::numeric_limits<float>::quiet_NaN()
        : static_cast<float>(g_smu.stapm_value);
}
float __stdcall FakeGetFastValue(void*) {
    return static_cast<float>(g_smu.fast_value);
}
float __stdcall FakeGetSlowValue(void*) {
    return static_cast<float>(g_smu.slow_value);
}
float __stdcall FakeGetTctlValue(void*) {
    return static_cast<float>(g_smu.tctl_value);
}
float __stdcall FakeGetTctlLimit(void*) {
    return static_cast<float>(g_smu.tctl_limit);
}

}  // namespace

namespace amd_mobile_power {
struct RyzenHardwareTestAccess {
    static void ConfigureFakes(RyzenHardware& hardware) {
        hardware.initialized_ = true;
        hardware.ryzen_access_ = reinterpret_cast<void*>(1);
        hardware.refresh_table_ = FakeRefreshTable;
        hardware.set_stapm_limit_ = FakeSetStapm;
        hardware.set_fast_limit_ = FakeSetFast;
        hardware.set_slow_limit_ = FakeSetSlow;
        hardware.get_stapm_limit_ = FakeGetStapmLimit;
        hardware.get_fast_limit_ = FakeGetFastLimit;
        hardware.get_slow_limit_ = FakeGetSlowLimit;
        hardware.get_stapm_value_ = FakeGetStapmValue;
        hardware.get_fast_value_ = FakeGetFastValue;
        hardware.get_slow_value_ = FakeGetSlowValue;
        hardware.get_tctl_value_ = FakeGetTctlValue;
        hardware.get_tctl_limit_ = FakeGetTctlLimit;
    }
};
}  // namespace amd_mobile_power

namespace {

void TestKnownOwnerNames() {
    using amd_mobile_power::IsKnownOwnerProcessName;
    Check(IsKnownOwnerProcessName(L"RyzenPower.exe"), "owner RyzenPower.exe");
    Check(IsKnownOwnerProcessName(L"RyzenPower"), "owner RyzenPower without extension");
    Check(IsKnownOwnerProcessName(L"ryzenadj.exe"), "owner ryzenadj.exe");
    Check(IsKnownOwnerProcessName(L"ryzenadj"), "owner ryzenadj without extension");
    Check(IsKnownOwnerProcessName(L"AMD Ryzen Master.exe"), "owner AMD Ryzen Master.exe");
    Check(IsKnownOwnerProcessName(L"AMD Ryzen Master"), "owner AMD Ryzen Master without extension");
    Check(IsKnownOwnerProcessName(L"RYZENPOWER.EXE"), "owner case-insensitive upper");
    Check(IsKnownOwnerProcessName(L"RyzenAdj.EXE"), "owner case-insensitive mixed");
    Check(IsKnownOwnerProcessName(L"amd ryzen master"), "owner case-insensitive lower");
    Check(!IsKnownOwnerProcessName(L""), "empty name is not an owner");
    Check(!IsKnownOwnerProcessName(L".exe"), "bare extension is not an owner");
    Check(!IsKnownOwnerProcessName(L"explorer.exe"), "unrelated process is not an owner");
    Check(!IsKnownOwnerProcessName(L"amdmobilepower_native_worker.exe"), "own worker is not an owner");
    Check(!IsKnownOwnerProcessName(L"amd-mobile-power-gui.exe"), "own GUI is not an owner");
    Check(!IsKnownOwnerProcessName(L"RyzenPower.exe.old"), "suffix variant is not an owner");
    Check(!IsKnownOwnerProcessName(L"RyzenPower.exe.exe"), "double extension is not an owner");
    Check(!IsKnownOwnerProcessName(L"ryzenadj.dll"), "library name is not an owner");
    Check(!IsKnownOwnerProcessName(L"RyzenMasterService.exe"), "service variant is not an owner");
    Check(!IsKnownOwnerProcessName(L"RyzenMaster.exe"), "RyzenMaster.exe is outside the .NET owner list");
    Check(!IsKnownOwnerProcessName(L"OtherPowerTool"), ".NET negative case stays negative");
}

void TestTelemetryClamp() {
    using amd_mobile_power::ComputeTelemetryClamp;
    using amd_mobile_power::PowerLimitTarget;
    const PowerLimitTarget target{30, 35, 28};
    const auto nan = std::numeric_limits<double>::quiet_NaN();
    const auto inf = std::numeric_limits<double>::infinity();

    Check(!ComputeTelemetryClamp(std::nullopt, 1.0, 1.0, 1.0),
        "no last target means no clamp");
    Check(!ComputeTelemetryClamp(target, 30.0, 35.0, 28.0),
        "exact limits are not clamped");
    Check(!ComputeTelemetryClamp(target, 31.0, 36.0, 29.0),
        "limits above request are not clamped");
    Check(!ComputeTelemetryClamp(target, 29.5, 34.25, 27.25),
        "limits exactly at tolerance are not clamped");
    Check(ComputeTelemetryClamp(target, 29.4, 35.0, 28.0),
        "STAPM below tolerance is clamped");
    Check(ComputeTelemetryClamp(target, 30.0, 34.2, 28.0),
        "Fast below tolerance is clamped");
    Check(ComputeTelemetryClamp(target, 30.0, 35.0, 27.2),
        "Slow below tolerance is clamped");
    Check(!ComputeTelemetryClamp(target, std::nullopt, std::nullopt, std::nullopt),
        "missing limits are ignored");
    Check(ComputeTelemetryClamp(target, std::nullopt, 10.0, std::nullopt),
        "one missing limit does not mask another clamped limit");
    Check(!ComputeTelemetryClamp(target, nan, inf, -inf),
        "non-finite limits are ignored");
    Check(ComputeTelemetryClamp(PowerLimitTarget{15, 15, 15}, 14.4, 15.0, 15.0),
        "STAPM tolerance is 0.5W not 0.75W");
    Check(!ComputeTelemetryClamp(PowerLimitTarget{15, 15, 15}, 15.0, 14.4, 15.0),
        "Fast tolerance is 0.75W not 0.5W");
}

void TestExtractJsonInt() {
    using amd_mobile_power::ExtractJsonInt;
    const auto json_for = [](std::string_view value) {
        return "{\"stapmWatts\":" + std::string(value) + "}";
    };
    const auto parse = [&](std::string_view value) {
        return ExtractJsonInt(json_for(value), "stapmWatts");
    };

    Check(parse("15") == 15, "plain integer");
    Check(parse("0") == 0, "zero");
    Check(parse("-5") == -5, "negative integer");
    Check(parse("-0") == 0, "negative zero");
    Check(parse("007") == 7, "leading zeros");
    Check(parse(" \t-12") == -12, "whitespace before value");
    Check(parse("12,") == 12, "trailing comma stops digits");
    Check(parse("5.9") == 5, "digit prefix before decimal point preserved");
    Check(parse(std::to_string(std::numeric_limits<int>::max())) ==
            std::numeric_limits<int>::max(),
        "INT_MAX parses");
    Check(parse(std::to_string(std::numeric_limits<int>::min())) ==
            std::numeric_limits<int>::min(),
        "INT_MIN parses");
    Check(!parse("2147483648").has_value(), "INT_MAX+1 rejected");
    Check(!parse("-2147483649").has_value(), "INT_MIN-1 rejected");
    Check(!parse("999999999999999999999999999999").has_value(),
        "huge positive magnitude rejected");
    Check(!parse("-999999999999999999999999999999").has_value(),
        "huge negative magnitude rejected");
    Check(!parse("18446744073709551616").has_value(), "2^64 rejected");
    Check(!parse(std::string(10000, '9')).has_value(),
        "10000-digit string rejected without overflow");
    Check(parse(std::string(100, '0') + "5") == 5,
        "long leading-zero run stays valid");
    Check(!parse("abc").has_value(), "non-numeric rejected");
    Check(!parse("-").has_value(), "bare minus rejected");
    Check(!parse("+5").has_value(), "plus sign rejected");
    Check(!parse("").has_value(), "empty value rejected");
    Check(!ExtractJsonInt(R"({"fastWatts":15})", "stapmWatts").has_value(),
        "missing key rejected");
    Check(!ExtractJsonInt(R"({"stapmWatts" 15})", "stapmWatts").has_value(),
        "missing colon rejected");
}

void TestPipeSecurityDescriptor() {
    using amd_mobile_power::PipeSecurityDescriptor;
    PipeSecurityDescriptor security;
    Check(security.attributes() == nullptr, "attributes null before initialize");
    Check(security.Initialize(), "security descriptor initializes");
    Check(security.Initialize(), "security descriptor initialize is idempotent");

    SECURITY_ATTRIBUTES* attributes = security.attributes();
    Check(attributes != nullptr, "attributes available after initialize");
    if (attributes == nullptr) { return; }
    Check(attributes->nLength == sizeof(SECURITY_ATTRIBUTES), "attributes length");
    Check(attributes->bInheritHandle == FALSE, "handle not inheritable");

    BOOL dacl_present = FALSE;
    BOOL dacl_defaulted = FALSE;
    PACL acl = nullptr;
    Check(GetSecurityDescriptorDacl(
            attributes->lpSecurityDescriptor, &dacl_present, &acl, &dacl_defaulted),
        "DACL readable");
    Check(dacl_present == TRUE, "explicit DACL present");
    Check(dacl_defaulted == FALSE, "DACL is not defaulted");
    if (acl == nullptr) { return; }

    ACL_SIZE_INFORMATION acl_info{};
    Check(GetAclInformation(acl, &acl_info, sizeof(acl_info), AclSizeInformation),
        "ACL size information readable");
    Check(acl_info.AceCount == 2, "exactly two ACEs (current user and SYSTEM)");

    // Independently resolve the expected SIDs through public APIs.
    DWORD token_user_size = 0;
    GetTokenInformation(GetCurrentProcessToken(), TokenUser, nullptr, 0, &token_user_size);
    std::string token_user_buffer(token_user_size, '\0');
    Check(GetTokenInformation(
            GetCurrentProcessToken(), TokenUser, token_user_buffer.data(),
            token_user_size, &token_user_size),
        "test reads current token user");
    const auto* token_user =
        reinterpret_cast<const TOKEN_USER*>(token_user_buffer.data());
    unsigned char system_sid_buffer[SECURITY_MAX_SID_SIZE]{};
    DWORD system_sid_size = sizeof(system_sid_buffer);
    Check(CreateWellKnownSid(
            WinLocalSystemSid, nullptr, system_sid_buffer, &system_sid_size),
        "test resolves SYSTEM SID");

    bool grants_user = false;
    bool grants_system = false;
    constexpr ACCESS_MASK kExpectedUserMask =
        GENERIC_READ | GENERIC_WRITE | SYNCHRONIZE;
    for (DWORD index = 0; index < acl_info.AceCount; ++index) {
        ACCESS_ALLOWED_ACE* ace = nullptr;
        if (!GetAce(acl, index, reinterpret_cast<LPVOID*>(&ace)) || ace == nullptr) {
            Check(false, "ACE readable");
            continue;
        }
        Check(ace->Header.AceType == ACCESS_ALLOWED_ACE_TYPE, "ACE is access-allowed");
        PSID sid = &ace->SidStart;
        if (EqualSid(sid, token_user->User.Sid)) {
            grants_user = true;
            Check(ace->Mask == kExpectedUserMask,
                "user ACE grants read/write/synchronize only");
        }
        if (EqualSid(sid, system_sid_buffer)) {
            grants_system = true;
            Check(ace->Mask == GENERIC_ALL, "SYSTEM ACE keeps GENERIC_ALL");
        }
    }
    Check(grants_user, "current user SID granted access");
    Check(grants_system, "SYSTEM SID granted access");
}

void TestHardwareTelemetryWithoutDriver() {
    using amd_mobile_power::LimitCapability;
    using amd_mobile_power::PlatformCapability;
    using amd_mobile_power::PowerLimitTarget;
    using amd_mobile_power::ProfileInfo;
    using amd_mobile_power::RyzenHardware;
    using amd_mobile_power::RyzenHardwareTestAccess;

    PlatformCapability capability;
    capability.is_supported = true;
    capability.limits = LimitCapability{true, true, true};
    ProfileInfo profile;
    profile.id = "fake-test-profile";
    profile.minimum_watts = 5;
    profile.maximum_watts = 45;
    capability.profile = profile;

    g_smu = FakeSmuState{};
    RyzenHardware hardware(L"");
    RyzenHardwareTestAccess::ConfigureFakes(hardware);

    std::string error;
    auto telemetry = hardware.Refresh(error);
    Check(error.empty(), "fake refresh succeeds");
    Check(!telemetry.target_watts.has_value(), "no target before first apply");
    Check(!telemetry.has_firmware_clamp, "no clamp before first apply");
    Check(telemetry.stapm_value_watts == 25.0, "fake stapm value read");

    g_smu.stapm_value_nan = true;
    g_smu.fast_limit_inf = true;
    telemetry = hardware.Refresh(error);
    Check(error.empty(), "refresh with non-finite inputs succeeds");
    Check(!telemetry.stapm_value_watts.has_value(), "NaN stapm value filtered");
    Check(!telemetry.fast_limit_watts.has_value(), "Inf fast limit filtered");
    Check(telemetry.slow_limit_watts == 28.0, "finite limits still read");
    g_smu.stapm_value_nan = false;
    g_smu.fast_limit_inf = false;

    const PowerLimitTarget target{30, 35, 28};
    auto result = hardware.ApplyTarget(target, capability);
    Check(result.IsSuccessful(), "fake apply succeeds");
    telemetry = hardware.Refresh(error);
    Check(telemetry.target_watts == 30.0, "target uses last applied stapm watts");
    Check(!telemetry.has_firmware_clamp, "exact readback is not clamped");

    g_smu.clamp_stapm_on_write = true;
    result = hardware.ApplyTarget(target, capability);
    Check(result.IsSuccessful(), "firmware STAPM clamp still applies successfully");
    telemetry = hardware.Refresh(error);
    Check(telemetry.target_watts == 30.0, "target persists after clamped apply");
    Check(telemetry.has_firmware_clamp, "persistent STAPM clamp detected");
    g_smu.clamp_stapm_on_write = false;

    g_smu.clamp_fast_on_write = true;
    result = hardware.ApplyTarget(target, capability);
    Check(result.IsSuccessful(), "firmware Fast clamp still applies successfully");
    telemetry = hardware.Refresh(error);
    Check(telemetry.has_firmware_clamp, "persistent Fast clamp detected");
    g_smu.clamp_fast_on_write = false;

    g_smu.set_result = 7;
    result = hardware.ApplyTarget(PowerLimitTarget{20, 20, 20}, capability);
    Check(!result.IsSuccessful(), "failed write reported");
    Check(result.restore_attempted, "failed write attempts restore");
    Check(!result.restored_previous_limits, "failed restore reported");
    telemetry = hardware.Refresh(error);
    Check(telemetry.target_watts == 30.0, "failed apply keeps last successful target");
    g_smu.set_result = 0;

    g_smu = FakeSmuState{};
    g_smu.set_result = 7;
    RyzenHardware fresh(L"");
    RyzenHardwareTestAccess::ConfigureFakes(fresh);
    result = fresh.ApplyTarget(target, capability);
    Check(!result.IsSuccessful(), "first apply can fail");
    telemetry = fresh.Refresh(error);
    Check(!telemetry.target_watts.has_value(), "failed first apply records no target");
    Check(!telemetry.has_firmware_clamp, "failed first apply records no clamp");
}

void TestHardwareUserCapWithoutDriver() {
    using amd_mobile_power::LimitCapability;
    using amd_mobile_power::PlatformCapability;
    using amd_mobile_power::PowerLimitTarget;
    using amd_mobile_power::ProfileInfo;
    using amd_mobile_power::RyzenHardware;
    using amd_mobile_power::RyzenHardwareTestAccess;

    PlatformCapability capability;
    capability.is_supported = true;
    capability.limits = LimitCapability{true, true, true};
    ProfileInfo profile;
    profile.id = "fake-test-profile";
    profile.minimum_watts = 5;
    profile.maximum_watts = 45;
    capability.profile = profile;

    g_smu = FakeSmuState{};
    RyzenHardware capped(L"", 25);
    RyzenHardwareTestAccess::ConfigureFakes(capped);

    auto result = capped.ApplyTarget(PowerLimitTarget{30, 35, 28}, capability);
    Check(!result.IsSuccessful(), "over-cap apply rejected");
    Check(result.error.has_value() &&
            result.error->find("user limit") != std::string::npos,
        "cap rejection explains the user limit");
    Check(g_smu.stapm_writes == 0 && g_smu.fast_writes == 0 &&
            g_smu.slow_writes == 0,
        "over-cap apply performs no hardware writes");
    Check(!result.restore_attempted, "cap rejection does not attempt restore");
    std::string error;
    auto telemetry = capped.Refresh(error);
    Check(!telemetry.target_watts.has_value(), "cap rejection records no target");

    result = capped.ApplyTarget(PowerLimitTarget{20, 26, 20}, capability);
    Check(!result.IsSuccessful(), "Fast above cap rejected");
    Check(g_smu.fast_writes == 0, "Fast cap rejection writes nothing");
    result = capped.ApplyTarget(PowerLimitTarget{20, 20, 26}, capability);
    Check(!result.IsSuccessful(), "Slow above cap rejected");
    Check(g_smu.slow_writes == 0, "Slow cap rejection writes nothing");

    result = capped.ApplyTarget(PowerLimitTarget{25, 25, 25}, capability);
    Check(result.IsSuccessful(), "target exactly at cap applies");
    Check(g_smu.stapm_writes == 1 && g_smu.fast_writes == 1 &&
            g_smu.slow_writes == 1,
        "at-cap apply writes each limit once");
    telemetry = capped.Refresh(error);
    Check(telemetry.target_watts == 25.0, "at-cap apply records target");

    g_smu = FakeSmuState{};
    RyzenHardware default_cap(L"");
    RyzenHardwareTestAccess::ConfigureFakes(default_cap);
    result = default_cap.ApplyTarget(PowerLimitTarget{50, 50, 50}, capability);
    Check(!result.IsSuccessful(), "profile maximum still enforced under default cap");
    Check(result.error.has_value() &&
            result.error->find("between") != std::string::npos,
        "profile range error preserved");
    Check(g_smu.stapm_writes == 0, "profile rejection writes nothing");
    result = default_cap.ApplyTarget(PowerLimitTarget{45, 45, 45}, capability);
    Check(result.IsSuccessful(), "profile maximum applies under default cap");
}

}  // namespace

int main() {
    TestKnownOwnerNames();
    TestTelemetryClamp();
    TestExtractJsonInt();
    TestPipeSecurityDescriptor();
    TestHardwareTelemetryWithoutDriver();
    TestHardwareUserCapWithoutDriver();
    if (failures != 0) {
        std::cerr << "worker_safety_tests: " << failures << " failure(s)\n";
        return 1;
    }
    std::cout << "worker_safety_tests: PASS (no driver loaded)\n";
    return 0;
}
