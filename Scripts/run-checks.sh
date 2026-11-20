#!/usr/bin/env bash
# 只编译不含 UI 的核心逻辑加上断言文件，跑一遍算钱的正确性。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/.build/checks"
# 源码扫描类检查按相对路径读文件，统一在仓库根目录下跑。
cd "$ROOT"
mkdir -p "$(dirname "$OUT")"

CORE_SOURCES=(
    "$ROOT/Sources/Fxxking_Work/Models/Configuration.swift"
    "$ROOT/Sources/Fxxking_Work/Models/Money.swift"
    "$ROOT/Sources/Fxxking_Work/Models/SalaryHistory.swift"
    "$ROOT/Sources/Fxxking_Work/Models/Overtime.swift"
    "$ROOT/Sources/Fxxking_Work/Models/Leave.swift"
    "$ROOT/Sources/Fxxking_Work/Models/PublicHoliday.swift"
    "$ROOT/Sources/Fxxking_Work/Support/Localization.swift"
    "$ROOT/Sources/Fxxking_Work/Support/Formatters.swift"
    "$ROOT/Sources/Fxxking_Work/Support/MenuBarLabel.swift"
    "$ROOT/Sources/Fxxking_Work/Services/TaxRules.swift"
    "$ROOT/Sources/Fxxking_Work/Services/PayrollCalendar.swift"
    "$ROOT/Sources/Fxxking_Work/Services/NetPayCalculator.swift"
    "$ROOT/Sources/Fxxking_Work/Services/WorkCalendar.swift"
    "$ROOT/Sources/Fxxking_Work/Services/EarningsEngine.swift"
    "$ROOT/Sources/Fxxking_Work/Services/PayrollReminderSchedule.swift"
    "$ROOT/Sources/Fxxking_Work/Services/GitHubHolidaysSource.swift"
    "$ROOT/Sources/Fxxking_Work/Services/HolidayService.swift"
)

swiftc -o "$OUT" "${CORE_SOURCES[@]}" "$ROOT/Checks/main.swift"
"$OUT"

# Exercise controller-to-ledger wiring with an isolated defaults suite.
swiftc -parse-as-library -o "$OUT-controller" "${CORE_SOURCES[@]}" \
    "$ROOT/Sources/Fxxking_Work/Models/SettingsStore.swift" \
    "$ROOT/Sources/Fxxking_Work/Models/CountryCatalog.swift" \
    "$ROOT/Sources/Fxxking_Work/Services/ScreenLockMonitor.swift" \
    "$ROOT/Sources/Fxxking_Work/Services/OvertimeController.swift" \
    "$ROOT/Checks/OvertimeControllerChecks.swift"
"$OUT-controller"

swiftc -parse-as-library -o "$OUT-privacy" "${CORE_SOURCES[@]}" \
    "$ROOT/Sources/Fxxking_Work/Models/SettingsStore.swift" \
    "$ROOT/Sources/Fxxking_Work/Models/CountryCatalog.swift" \
    "$ROOT/Sources/Fxxking_Work/Support/PrivacyController.swift" \
    "$ROOT/Checks/PrivacyControllerChecks.swift"
"$OUT-privacy"

swiftc -o "$OUT-screen-capture" \
    "$ROOT/Sources/Fxxking_Work/Support/ScreenCaptureStatusLog.swift" \
    "$ROOT/Checks/ScreenCaptureStatusLogChecks.swift"
"$OUT-screen-capture"

# 短采集打断面板：保护层策略 + 保护层外状态保留（纯逻辑，不加载 SwiftUI 视图）。
swiftc -parse-as-library -o "$OUT-protection" "${CORE_SOURCES[@]}" \
    "$ROOT/Sources/Fxxking_Work/Support/ScreenCaptureStatusLog.swift" \
    "$ROOT/Sources/Fxxking_Work/Support/ScreenCaptureProtectionPolicy.swift" \
    "$ROOT/Sources/Fxxking_Work/Support/LeaveReasonSession.swift" \
    "$ROOT/Sources/Fxxking_Work/Support/PanelUIState.swift" \
    "$ROOT/Sources/Fxxking_Work/Support/SettingsUIState.swift" \
    "$ROOT/Sources/Fxxking_Work/Support/OnboardingDraftState.swift" \
    "$ROOT/Sources/Fxxking_Work/Services/LeaveReasonGenerator.swift" \
    "$ROOT/Sources/Fxxking_Work/Views/LeaveReasonGeneratorView.swift" \
    "$ROOT/Checks/ScreenCaptureProtectionChecks.swift"
"$OUT-protection"

swiftc -parse-as-library -o "$OUT-leave" "${CORE_SOURCES[@]}" \
    "$ROOT/Sources/Fxxking_Work/Models/SettingsStore.swift" \
    "$ROOT/Sources/Fxxking_Work/Models/CountryCatalog.swift" \
    "$ROOT/Sources/Fxxking_Work/Services/LeaveController.swift" \
    "$ROOT/Checks/LeaveControllerChecks.swift"
"$OUT-leave"

swiftc -parse-as-library -o "$OUT-settings" "${CORE_SOURCES[@]}" \
    "$ROOT/Sources/Fxxking_Work/Models/SettingsStore.swift" \
    "$ROOT/Sources/Fxxking_Work/Models/CountryCatalog.swift" \
    "$ROOT/Checks/SettingsStateChecks.swift"
"$OUT-settings"

swiftc -parse-as-library -o "$OUT-reason" "${CORE_SOURCES[@]}" \
    "$ROOT/Sources/Fxxking_Work/Services/LeaveReasonGenerator.swift" \
    "$ROOT/Checks/LeaveReasonGeneratorChecks.swift"
"$OUT-reason"

# 面板内会话接线：生成器状态由 LeaveReasonSession 持有，连续抽取不重复。
swiftc -parse-as-library -o "$OUT-reason-session" "${CORE_SOURCES[@]}" \
    "$ROOT/Sources/Fxxking_Work/Services/LeaveReasonGenerator.swift" \
    "$ROOT/Sources/Fxxking_Work/Support/LeaveReasonSession.swift" \
    "$ROOT/Sources/Fxxking_Work/Views/LeaveReasonGeneratorView.swift" \
    "$ROOT/Checks/LeaveReasonSessionChecks.swift"
"$OUT-reason-session"

# 保护打断请假/加班编辑时的草稿：恢复、取消不恢复、不落盘、sheet 也包保护层。
swiftc -parse-as-library -o "$OUT-drafts" "${CORE_SOURCES[@]}" \
    "$ROOT/Sources/Fxxking_Work/Support/EditingDrafts.swift" \
    "$ROOT/Checks/EditingDraftChecks.swift"
"$OUT-drafts"

# 语言选项、旧设置解码兼容与 ja/ko 资源边界。
swiftc -parse-as-library -o "$OUT-localization" "${CORE_SOURCES[@]}" \
    "$ROOT/Checks/LocalizationChecks.swift"
"$OUT-localization"
