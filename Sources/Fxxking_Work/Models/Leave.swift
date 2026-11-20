import Foundation

/// 请假类型只用于分类和记录，具体是否计薪由每条记录的比例决定。
enum LeaveKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case personal
    case sick
    case annual
    case compensatory
    case marriage
    case bereavement
    case maternity
    case paternity
    case other

    var id: String { rawValue }

    /// 仅作为新建记录时的默认值，用户可以在保存前修改。
    var defaultPayRatioBp: Int {
        switch self {
        case .personal: return 0
        case .sick: return 6_000
        case .annual, .compensatory, .marriage, .bereavement, .maternity, .paternity:
            return 10_000
        case .other: return 0
        }
    }
}

enum LeavePortion: String, Codable, CaseIterable, Identifiable, Sendable {
    case fullDay
    case morning
    case afternoon

    var id: String { rawValue }

    var leaveFraction: Double {
        self == .fullDay ? 1 : 0.5
    }
}

struct LeaveEntry: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    /// 本地日历年月日；与 `DayKeyCoder.current` 使用同一时区。
    var dayKey: String
    var kind: LeaveKind
    var portion: LeavePortion
    /// 请假部分计入工资的比例，0…10000（基点）。
    var payRatioBp: Int
    var note: String

    init(
        id: UUID = UUID(),
        dayKey: String,
        kind: LeaveKind,
        portion: LeavePortion,
        payRatioBp: Int? = nil,
        note: String = ""
    ) {
        self.id = id
        self.dayKey = dayKey
        self.kind = kind
        self.portion = portion
        self.payRatioBp = payRatioBp ?? kind.defaultPayRatioBp
        self.note = note
    }

    var leaveFraction: Double { portion.leaveFraction }

    var payRatio: Double {
        Double(min(max(payRatioBp, 0), 10_000)) / 10_000
    }

    /// 这一天相对于正常日薪的应发比例。
    var payableFraction: Double {
        let workingFraction = 1 - leaveFraction
        return workingFraction + leaveFraction * payRatio
    }
}

enum LeaveLedgerError: Error, Equatable {
    case duplicateDate
    case invalidPayRatio
}

struct LeaveLedger {
    var entries: [LeaveEntry]

    init(entries: [LeaveEntry]) {
        self.entries = entries.sorted { $0.dayKey < $1.dayKey }
    }

    func entry(on dayKey: String) -> LeaveEntry? {
        entries.first { $0.dayKey == dayKey }
    }

    mutating func upsert(_ entry: LeaveEntry) -> Result<LeaveEntry, LeaveLedgerError> {
        guard (0...10_000).contains(entry.payRatioBp) else {
            return .failure(.invalidPayRatio)
        }
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            guard self.entry(on: entry.dayKey) == nil else {
                return .failure(.duplicateDate)
            }
            entries.append(entry)
        }
        entries.sort { $0.dayKey < $1.dayKey }
        return .success(entry)
    }

    mutating func remove(id: UUID) {
        entries.removeAll { $0.id == id }
    }
}
