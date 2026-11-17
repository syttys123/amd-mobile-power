#include "../src/power_policy.hpp"

#include <chrono>
#include <iostream>
#include <limits>
#include <optional>
#include <string>

namespace {

using amd_mobile_power::IPowerPolicyBackend;
using amd_mobile_power::PlatformCapability;
using amd_mobile_power::PowerLimitApplicationResult;
using amd_mobile_power::PowerLimitTarget;
using amd_mobile_power::PowerLineState;
using amd_mobile_power::PowerPolicyController;
using amd_mobile_power::PowerPolicyObservation;
using amd_mobile_power::PowerPolicySettings;

struct FakePolicyBackend final : IPowerPolicyBackend {
    PlatformCapability capability;
    PowerLineState power_line = PowerLineState::Battery;
    std::optional<double> stapm_limit_watts;
    std::optional<double> fast_limit_watts;
    std::optional<double> slow_limit_watts;
    bool observe_failure = false;
    bool apply_failure = false;
    int observe_count = 0;
    int apply_count = 0;
    std::optional<PowerLimitTarget> last_target;

    bool Observe(
        PowerPolicyObservation& observation,
        std::string& error) override {
        ++observe_count;
        if (observe_failure) {
            error = "observation failed";
            return false;
        }
        observation.platform = capability;
        observation.power_line = power_line;
        observation.stapm_limit_watts = stapm_limit_watts;
        observation.fast_limit_watts = fast_limit_watts;
        observation.slow_limit_watts = slow_limit_watts;
        return true;
    }

    PowerLimitApplicationResult ApplyTarget(
        const PowerLimitTarget& target,
        const PlatformCapability&) override {
        ++apply_count;
        last_target = target;
        PowerLimitApplicationResult result;
        result.target = target;
        if (apply_failure) {
            result.error = "apply failed";
        }
        return result;
    }
};

bool Expect(bool condition, const char* message) {
    if (!condition) {
        std::cerr << "FAILED: " << message << "\n";
        return false;
    }
    return true;
}

PlatformCapability SupportedCapability() {
    PlatformCapability capability;
    capability.is_supported = true;
    capability.profile = amd_mobile_power::ProfileInfo{
        "test-profile",
        "Test profile",
        5,
        60,
        25,
        true};
    capability.limits.supports_stapm = true;
    capability.limits.supports_fast = true;
    capability.limits.supports_slow = true;
    return capability;
}

void TickAt(
    FakePolicyBackend& backend,
    PowerPolicyController& controller,
    std::chrono::steady_clock::time_point start,
    int seconds) {
    controller.Tick(
        backend,
        start + std::chrono::seconds(seconds),
        "2026-11-18T00:00:00Z");
}

bool AppliesBatteryThenAcWhenPowerLineChanges() {
    FakePolicyBackend backend;
    backend.capability = SupportedCapability();
    PowerPolicyController controller;
    controller.SetSettings(PowerPolicySettings{
        true,
        PowerLimitTarget::uniform(12),
        PowerLimitTarget::uniform(45)});

    const auto start = std::chrono::steady_clock::now();
    controller.Tick(backend, start, "2026-11-10T00:00:00Z");
    const bool battery_applied =
        backend.apply_count == 1 &&
        backend.last_target == std::optional<PowerLimitTarget>(
            PowerLimitTarget::uniform(12)) &&
        controller.state().last_observed_power_line ==
            std::optional<PowerLineState>(PowerLineState::Battery) &&
        controller.state().last_attempt_succeeded == std::optional<bool>(true);

    controller.Tick(
        backend,
        start + std::chrono::seconds(1),
        "2026-11-10T00:00:01Z");
    const bool unchanged_is_not_reapplied = backend.apply_count == 1;

    backend.power_line = PowerLineState::Ac;
    controller.Tick(
        backend,
        start + std::chrono::seconds(2),
        "2026-11-10T00:00:02Z");
    const bool ac_applied =
        backend.apply_count == 2 &&
        backend.last_target == std::optional<PowerLimitTarget>(
            PowerLimitTarget::uniform(45)) &&
        controller.state().last_applied_target ==
            std::optional<PowerLimitTarget>(PowerLimitTarget::uniform(45));

    return Expect(battery_applied, "battery target should be applied first") &&
        Expect(
            unchanged_is_not_reapplied,
            "the same power line should not be written repeatedly") &&
        Expect(ac_applied, "AC target should be applied after a power-line change");
}

bool RetriesFailedPolicyAfterBackoff() {
    FakePolicyBackend backend;
    backend.capability = SupportedCapability();
    backend.apply_failure = true;
    PowerPolicyController controller;
    controller.SetSettings(PowerPolicySettings{
        true,
        PowerLimitTarget::uniform(12),
        PowerLimitTarget::uniform(45)});

    const auto start = std::chrono::steady_clock::now();
    controller.Tick(backend, start, "2026-11-10T00:00:00Z");
    const bool first_failure_is_reported =
        backend.apply_count == 1 &&
        controller.state().last_attempt_succeeded == std::optional<bool>(false) &&
        controller.state().last_error == std::optional<std::string>("apply failed");

    controller.Tick(
        backend,
        start + std::chrono::seconds(1),
        "2026-11-10T00:00:01Z");
    const bool backoff_skips_retry = backend.apply_count == 1;

    controller.Tick(
        backend,
        start + std::chrono::seconds(6),
        "2026-11-10T00:00:06Z");
    const bool retry_after_backoff = backend.apply_count == 2;

    return Expect(first_failure_is_reported, "first policy failure should be reported") &&
        Expect(backoff_skips_retry, "a failed policy target should back off") &&
        Expect(retry_after_backoff, "a failed policy target should retry after five seconds");
}

bool DisabledPolicyDoesNotTouchHardware() {
    FakePolicyBackend backend;
    backend.capability = SupportedCapability();
    PowerPolicyController controller;
    controller.SetSettings(PowerPolicySettings{
        false,
        PowerLimitTarget::uniform(12),
        PowerLimitTarget::uniform(45)});

    controller.Tick(
        backend,
        std::chrono::steady_clock::now(),
        "2026-11-10T00:00:00Z");
    return Expect(backend.observe_count == 0, "disabled policy should not observe hardware") &&
        Expect(backend.apply_count == 0, "disabled policy should not apply a target");
}

bool UnknownPowerLineIsRejected() {
    FakePolicyBackend backend;
    backend.capability = SupportedCapability();
    backend.power_line = PowerLineState::Unknown;
    PowerPolicyController controller;
    controller.SetSettings(PowerPolicySettings{
        true,
        PowerLimitTarget::uniform(12),
        PowerLimitTarget::uniform(45)});

    controller.Tick(
        backend,
        std::chrono::steady_clock::now(),
        "2026-11-10T00:00:00Z");
    return Expect(backend.apply_count == 0, "unknown power line should not apply a target") &&
        Expect(
            controller.state().last_attempt_succeeded == std::optional<bool>(false),
            "unknown power line should be surfaced as a policy failure");
}

bool BatteryOnlyPolicySkipsAcAndAppliesOnBattery() {
    FakePolicyBackend backend;
    backend.capability = SupportedCapability();
    backend.power_line = PowerLineState::Ac;
    PowerPolicyController controller;
    PowerPolicySettings settings;
    settings.enabled = true;
    settings.battery_target = PowerLimitTarget::uniform(10);
    settings.ac_target = PowerLimitTarget::uniform(45);
    settings.battery_enabled = true;
    settings.ac_enabled = false;
    controller.SetSettings(settings);

    const auto start = std::chrono::steady_clock::now();
    controller.Tick(backend, start, "2026-11-11T00:00:00Z");
    const bool ac_skipped =
        backend.apply_count == 0 &&
        controller.state().last_observed_power_line ==
            std::optional<PowerLineState>(PowerLineState::Ac) &&
        !controller.state().last_attempt_succeeded.has_value();

    backend.power_line = PowerLineState::Battery;
    controller.Tick(
        backend,
        start + std::chrono::seconds(1),
        "2026-11-11T00:00:01Z");
    const bool battery_applied =
        backend.apply_count == 1 &&
        backend.last_target == std::optional<PowerLimitTarget>(
            PowerLimitTarget::uniform(10)) &&
        controller.state().last_attempt_succeeded == std::optional<bool>(true);

    return Expect(ac_skipped, "battery-only policy should not touch AC") &&
        Expect(
            battery_applied,
            "battery-only policy should still apply on battery");
}

bool ObservationWithoutAttemptKeepsTheAttemptLine() {
    FakePolicyBackend backend;
    backend.capability = SupportedCapability();
    backend.power_line = PowerLineState::Battery;
    PowerPolicyController controller;
    PowerPolicySettings settings;
    settings.enabled = true;
    settings.battery_target = PowerLimitTarget::uniform(10);
    settings.ac_target = PowerLimitTarget::uniform(45);
    settings.battery_enabled = true;
    settings.ac_enabled = false;
    controller.SetSettings(settings);

    const auto start = std::chrono::steady_clock::now();
    TickAt(backend, controller, start, 0);
    const auto first_attempt_at = controller.state().last_attempt_at;
    const bool battery_applied =
        backend.apply_count == 1 &&
        controller.state().last_attempt_power_line ==
            std::optional<PowerLineState>(PowerLineState::Battery) &&
        controller.state().last_applied_power_line ==
            std::optional<PowerLineState>(PowerLineState::Battery);

    TickAt(backend, controller, start, 1);
    const bool same_line_noop_keeps_attempt =
        backend.apply_count == 1 &&
        controller.state().last_observed_power_line ==
            std::optional<PowerLineState>(PowerLineState::Battery) &&
        controller.state().last_attempt_power_line ==
            std::optional<PowerLineState>(PowerLineState::Battery) &&
        controller.state().last_attempt_at == first_attempt_at;

    backend.power_line = PowerLineState::Ac;
    TickAt(backend, controller, start, 2);
    const bool observation_moved_without_attempt =
        backend.apply_count == 1 &&
        controller.state().last_observed_power_line ==
            std::optional<PowerLineState>(PowerLineState::Ac) &&
        controller.state().last_attempt_power_line ==
            std::optional<PowerLineState>(PowerLineState::Battery) &&
        controller.state().last_applied_power_line ==
            std::optional<PowerLineState>(PowerLineState::Battery) &&
        controller.state().last_attempt_at == first_attempt_at;

    return Expect(battery_applied, "battery attempt line should be recorded") &&
        Expect(
            same_line_noop_keeps_attempt,
            "a same-line no-op tick must not move the attempt line or timestamp") &&
        Expect(
            observation_moved_without_attempt,
            "an excluded line may update the observation without changing the attempt line");
}

bool FailedApplyRecordsTheAttemptLine() {
    FakePolicyBackend backend;
    backend.capability = SupportedCapability();
    backend.power_line = PowerLineState::Battery;
    backend.apply_failure = true;
    PowerPolicyController controller;
    controller.SetSettings(PowerPolicySettings{
        true,
        PowerLimitTarget::uniform(12),
        PowerLimitTarget::uniform(45)});

    TickAt(backend, controller, std::chrono::steady_clock::now(), 0);

    return Expect(backend.apply_count == 1, "the failing target should be attempted once") &&
        Expect(
            controller.state().last_attempt_power_line ==
                std::optional<PowerLineState>(PowerLineState::Battery),
            "a failed apply should record the attempted power line") &&
        Expect(
            !controller.state().last_applied_power_line.has_value(),
            "a failed apply must not claim a successful power line") &&
        Expect(
            controller.state().last_attempt_succeeded == std::optional<bool>(false),
            "the failed attempt should be surfaced");
}

bool PowerLineSwitchUpdatesAttemptAndAppliedLines() {
    FakePolicyBackend backend;
    backend.capability = SupportedCapability();
    backend.power_line = PowerLineState::Battery;
    PowerPolicyController controller;
    controller.SetSettings(PowerPolicySettings{
        true,
        PowerLimitTarget::uniform(12),
        PowerLimitTarget::uniform(45)});

    const auto start = std::chrono::steady_clock::now();
    TickAt(backend, controller, start, 0);
    backend.power_line = PowerLineState::Ac;
    TickAt(backend, controller, start, 1);

    return Expect(backend.apply_count == 2, "the AC target should be applied after a line switch") &&
        Expect(
            controller.state().last_attempt_power_line ==
                std::optional<PowerLineState>(PowerLineState::Ac),
            "a line switch should update the attempt line") &&
        Expect(
            controller.state().last_applied_power_line ==
                std::optional<PowerLineState>(PowerLineState::Ac),
            "a successful line switch should update the applied line") &&
        Expect(
            controller.state().last_applied_target ==
                std::optional<PowerLimitTarget>(PowerLimitTarget::uniform(45)),
            "a successful line switch should update the applied target");
}

bool UnsupportedPlatformFailureRecordsTheAttemptLine() {
    FakePolicyBackend backend;
    backend.capability = SupportedCapability();
    backend.capability.is_supported = false;
    backend.capability.unsupported_reason = "unsupported test platform";
    backend.power_line = PowerLineState::Battery;
    PowerPolicyController controller;
    controller.SetSettings(PowerPolicySettings{
        true,
        PowerLimitTarget::uniform(12),
        PowerLimitTarget::uniform(45)});

    TickAt(backend, controller, std::chrono::steady_clock::now(), 0);

    return Expect(backend.apply_count == 0, "unsupported platforms must not write") &&
        Expect(
            controller.state().last_attempt_power_line ==
                std::optional<PowerLineState>(PowerLineState::Battery),
            "a known-line policy failure should record the attempted line") &&
        Expect(
            controller.state().last_attempt_succeeded == std::optional<bool>(false),
            "the unsupported platform failure should be surfaced");
}

bool SetSettingsResetsAttemptAndAppliedLines() {
    FakePolicyBackend backend;
    backend.capability = SupportedCapability();
    backend.power_line = PowerLineState::Battery;
    PowerPolicyController controller;
    controller.SetSettings(PowerPolicySettings{
        true,
        PowerLimitTarget::uniform(12),
        PowerLimitTarget::uniform(45)});
    TickAt(backend, controller, std::chrono::steady_clock::now(), 0);

    controller.SetSettings(PowerPolicySettings{
        true,
        PowerLimitTarget::uniform(20),
        PowerLimitTarget::uniform(50)});

    const auto& state = controller.state();
    return Expect(
               !state.last_observed_power_line.has_value() &&
                   !state.last_attempt_power_line.has_value() &&
                   !state.last_applied_power_line.has_value(),
               "new settings should clear observation, attempt, and applied lines") &&
        Expect(
            !state.last_applied_target.has_value() &&
                !state.last_attempt_succeeded.has_value(),
            "new settings should clear the old result");
}

bool HighFastDriftIsReapplied() {
    FakePolicyBackend backend;
    backend.capability = SupportedCapability();
    backend.stapm_limit_watts = 12;
    backend.fast_limit_watts = 20;
    backend.slow_limit_watts = 30;
    PowerPolicyController controller;
    const PowerLimitTarget battery_target{12, 20, 30};
    controller.SetSettings(PowerPolicySettings{
        true,
        battery_target,
        PowerLimitTarget::uniform(45)});

    const auto start = std::chrono::steady_clock::now();
    TickAt(backend, controller, start, 0);
    backend.fast_limit_watts = 20.8;
    TickAt(backend, controller, start, 1);

    return Expect(backend.apply_count == 2, "upper Fast drift should reapply the target") &&
        Expect(
            backend.last_target == std::optional<PowerLimitTarget>(battery_target),
            "Fast drift should reapply the same line target");
}

bool HighSlowDriftIsReapplied() {
    FakePolicyBackend backend;
    backend.capability = SupportedCapability();
    backend.stapm_limit_watts = 12;
    backend.fast_limit_watts = 20;
    backend.slow_limit_watts = 30;
    PowerPolicyController controller;
    const PowerLimitTarget battery_target{12, 20, 30};
    controller.SetSettings(PowerPolicySettings{
        true,
        battery_target,
        PowerLimitTarget::uniform(45)});

    const auto start = std::chrono::steady_clock::now();
    TickAt(backend, controller, start, 0);
    backend.slow_limit_watts = 30.8;
    TickAt(backend, controller, start, 1);

    return Expect(backend.apply_count == 2, "upper Slow drift should reapply the target") &&
        Expect(
            backend.last_target == std::optional<PowerLimitTarget>(battery_target),
            "Slow drift should reapply the same line target");
}

bool MatchingLimitsDoNotReapply() {
    FakePolicyBackend backend;
    backend.capability = SupportedCapability();
    backend.stapm_limit_watts = 12;
    backend.fast_limit_watts = 20;
    backend.slow_limit_watts = 30;
    PowerPolicyController controller;
    controller.SetSettings(PowerPolicySettings{
        true,
        PowerLimitTarget{12, 20, 30},
        PowerLimitTarget::uniform(45)});

    const auto start = std::chrono::steady_clock::now();
    TickAt(backend, controller, start, 0);
    TickAt(backend, controller, start, 1);
    backend.fast_limit_watts = 20.5;
    backend.slow_limit_watts = 30.5;
    TickAt(backend, controller, start, 2);

    return Expect(
        backend.apply_count == 1,
        "matching limits and values within tolerance should not reapply");
}

bool LowerFastAndSlowClampsDoNotReapply() {
    FakePolicyBackend backend;
    backend.capability = SupportedCapability();
    backend.stapm_limit_watts = 12;
    backend.fast_limit_watts = 20;
    backend.slow_limit_watts = 30;
    PowerPolicyController controller;
    controller.SetSettings(PowerPolicySettings{
        true,
        PowerLimitTarget{12, 20, 30},
        PowerLimitTarget::uniform(45)});

    const auto start = std::chrono::steady_clock::now();
    TickAt(backend, controller, start, 0);
    backend.fast_limit_watts = 18;
    backend.slow_limit_watts = 28;
    TickAt(backend, controller, start, 1);

    return Expect(
        backend.apply_count == 1,
        "firmware Fast and Slow clamps below target should not reapply");
}

bool StapmOnlyDriftDoesNotReapply() {
    FakePolicyBackend backend;
    backend.capability = SupportedCapability();
    backend.stapm_limit_watts = 12;
    backend.fast_limit_watts = 20;
    backend.slow_limit_watts = 30;
    PowerPolicyController controller;
    controller.SetSettings(PowerPolicySettings{
        true,
        PowerLimitTarget{12, 20, 30},
        PowerLimitTarget::uniform(45)});

    const auto start = std::chrono::steady_clock::now();
    TickAt(backend, controller, start, 0);
    backend.stapm_limit_watts = 55;
    TickAt(backend, controller, start, 1);

    return Expect(
        backend.apply_count == 1,
        "STAPM-only drift should not reapply Fast or Slow targets");
}

bool MissingAndNonFiniteLimitsDoNotReapply() {
    FakePolicyBackend backend;
    backend.capability = SupportedCapability();
    backend.stapm_limit_watts = 12;
    backend.fast_limit_watts = 20;
    backend.slow_limit_watts = 30;
    PowerPolicyController controller;
    controller.SetSettings(PowerPolicySettings{
        true,
        PowerLimitTarget{12, 20, 30},
        PowerLimitTarget::uniform(45)});

    const auto start = std::chrono::steady_clock::now();
    TickAt(backend, controller, start, 0);
    backend.fast_limit_watts.reset();
    backend.slow_limit_watts = std::numeric_limits<double>::quiet_NaN();
    TickAt(backend, controller, start, 1);

    return Expect(
        backend.apply_count == 1,
        "missing or non-finite limits should not trigger a reapply");
}

bool DriftRetryUsesFailureBackoff() {
    FakePolicyBackend backend;
    backend.capability = SupportedCapability();
    backend.stapm_limit_watts = 12;
    backend.fast_limit_watts = 20;
    backend.slow_limit_watts = 30;
    PowerPolicyController controller;
    controller.SetSettings(PowerPolicySettings{
        true,
        PowerLimitTarget{12, 20, 30},
        PowerLimitTarget::uniform(45)});

    const auto start = std::chrono::steady_clock::now();
    TickAt(backend, controller, start, 0);
    backend.apply_failure = true;
    backend.fast_limit_watts = 21;
    TickAt(backend, controller, start, 1);
    const bool drift_attempt_failed =
        backend.apply_count == 2 &&
        controller.state().last_attempt_succeeded == std::optional<bool>(false);

    TickAt(backend, controller, start, 5);
    const bool backoff_skips_retry = backend.apply_count == 2;
    TickAt(backend, controller, start, 6);

    return Expect(drift_attempt_failed, "drift repair failure should be reported") &&
        Expect(backoff_skips_retry, "drift repair should honor the five-second backoff") &&
        Expect(backend.apply_count == 3, "drift repair should retry after five seconds");
}

bool LineSwitchStillAppliesTheNewTarget() {
    FakePolicyBackend backend;
    backend.capability = SupportedCapability();
    backend.stapm_limit_watts = 12;
    backend.fast_limit_watts = 12;
    backend.slow_limit_watts = 12;
    PowerPolicyController controller;
    controller.SetSettings(PowerPolicySettings{
        true,
        PowerLimitTarget::uniform(12),
        PowerLimitTarget::uniform(45)});

    const auto start = std::chrono::steady_clock::now();
    TickAt(backend, controller, start, 0);
    backend.power_line = PowerLineState::Ac;
    TickAt(backend, controller, start, 1);

    return Expect(backend.apply_count == 2, "a power-line switch should always apply") &&
        Expect(
            backend.last_target ==
                std::optional<PowerLimitTarget>(PowerLimitTarget::uniform(45)),
            "a power-line switch should apply the new line target immediately");
}

}  // namespace

int main() {
    const bool passed =
        AppliesBatteryThenAcWhenPowerLineChanges() &&
        RetriesFailedPolicyAfterBackoff() &&
        DisabledPolicyDoesNotTouchHardware() &&
        UnknownPowerLineIsRejected() &&
        BatteryOnlyPolicySkipsAcAndAppliesOnBattery() &&
        ObservationWithoutAttemptKeepsTheAttemptLine() &&
        FailedApplyRecordsTheAttemptLine() &&
        PowerLineSwitchUpdatesAttemptAndAppliedLines() &&
        UnsupportedPlatformFailureRecordsTheAttemptLine() &&
        SetSettingsResetsAttemptAndAppliedLines() &&
        HighFastDriftIsReapplied() &&
        HighSlowDriftIsReapplied() &&
        MatchingLimitsDoNotReapply() &&
        LowerFastAndSlowClampsDoNotReapply() &&
        StapmOnlyDriftDoesNotReapply() &&
        MissingAndNonFiniteLimitsDoNotReapply() &&
        DriftRetryUsesFailureBackoff() &&
        LineSwitchStillAppliesTheNewTarget();
    if (!passed) {
        return 1;
    }
    std::cout << "power_policy_tests: PASS\n";
    return 0;
}
