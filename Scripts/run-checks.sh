#!/usr/bin/env bash
# 只编译不含 UI 的核心逻辑加上断言文件，跑一遍算钱的正确性。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/.build/checks"
mkdir -p "$(dirname "$OUT")"

CORE_SOURCES=(
    "$ROOT/Sources/Fxxking_Work/Models/Configuration.swift"
    "$ROOT/Sources/Fxxking_Work/Models/Money.swift"
    "$ROOT/Sources/Fxxking_Work/Models/SalaryHistory.swift"
    "$ROOT/Sources/Fxxking_Work/Models/Overtime.swift"
    "$ROOT/Sources/Fxxking_Work/Models/PublicHoliday.swift"
    "$ROOT/Sources/Fxxking_Work/Support/Localization.swift"
    "$ROOT/Sources/Fxxking_Work/Support/Formatters.swift"
    "$ROOT/Sources/Fxxking_Work/Support/MenuBarLabel.swift"
    "$ROOT/Sources/Fxxking_Work/Services/TaxRules.swift"
    "$ROOT/Sources/Fxxking_Work/Services/PayrollCalendar.swift"
    "$ROOT/Sources/Fxxking_Work/Services/NetPayCalculator.swift"
    "$ROOT/Sources/Fxxking_Work/Services/WorkCalendar.swift"
    "$ROOT/Sources/Fxxking_Work/Services/EarningsEngine.swift"
    "$ROOT/Sources/Fxxking_Work/Services/GitHubHolidaysSource.swift"
    "$ROOT/Sources/Fxxking_Work/Services/HolidayService.swift"
)

swiftc -o "$OUT" "${CORE_SOURCES[@]}" "$ROOT/Checks/main.swift"
"$OUT"

# Exercise controller-to-ledger wiring with an isolated defaults suite.
swiftc -parse-as-library -o "$OUT-controller" "${CORE_SOURCES[@]}" \
    "$ROOT/Sources/Fxxking_Work/Models/SettingsStore.swift" \
    "$ROOT/Sources/Fxxking_Work/Models/CountryCatalog.swift" \
    "$ROOT/Sources/Fxxking_Work/Services/OvertimeController.swift" \
    "$ROOT/Checks/OvertimeControllerChecks.swift"
"$OUT-controller"
