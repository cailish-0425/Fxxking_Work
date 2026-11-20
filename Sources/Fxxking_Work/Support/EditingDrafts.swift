import Foundation

/// 屏幕共享保护会把编辑器所在的视图**整体移出视图树**（这是隐私要求，不能退回遮罩/透明度），
/// 视图里的 `@State` 会跟着销毁；未保存的输入如果只存在 `@State` 里，一次普通截图就没了。
///
/// 所以未保存的输入放到这里：只存内存、**不落盘、不写配置**，
/// 写入配置仍然只发生在用户点「保存」的那一次。草稿只在三种情况下清掉：
/// 用户点「保存 / 删除 / 取消 / 完成」，或超过 `maxAge` 自然过期。
/// 保护期打断**不清**草稿，因此短采集结束后重新打开编辑器还能接着填。

enum LeavePayOption: String, CaseIterable, Identifiable {
    case unpaid
    case full
    case custom

    var id: String { rawValue }

    /// 自定义档之外的两档对应的基点值。
    var fixedBasisPoints: Int? {
        switch self {
        case .unpaid: return 0
        case .full: return 10_000
        case .custom: return nil
        }
    }

    /// 由已存的基点值反推出应该选中哪一档。
    static func option(for basisPoints: Int) -> LeavePayOption {
        switch basisPoints {
        case 0: return .unpaid
        case 10_000: return .full
        default: return .custom
        }
    }
}

// MARK: - 请假单日草稿

struct LeaveDayEditorDraft: Equatable {
    var day: Date
    var kind: LeaveKind
    var portion: LeavePortion
    var payOption: LeavePayOption
    var customBasisPoints: Int
    var note: String

    /// 打开编辑器时的初值：有既有记录就从记录读，没有就按默认假种。
    static func seed(day: Date, existing: LeaveEntry?) -> LeaveDayEditorDraft {
        let kind = existing?.kind ?? .personal
        let ratio = existing?.payRatioBp ?? kind.defaultPayRatioBp
        return LeaveDayEditorDraft(
            day: day,
            kind: kind,
            portion: existing?.portion ?? .fullDay,
            payOption: LeavePayOption.option(for: ratio),
            customBasisPoints: ratio,
            note: existing?.note ?? ""
        )
    }

    /// 编辑既有记录：日期以记录为准。
    static func seed(entry: LeaveEntry) -> LeaveDayEditorDraft {
        let day = DayKeyCoder.current.date(from: entry.dayKey) ?? Date()
        return seed(day: day, existing: entry)
    }

    var dayKey: String { DayKeyCoder.current.key(for: day) }

    /// 不计薪 / 100% 计薪是固定档，自定义档才用用户填的值。
    var resolvedBasisPoints: Int {
        payOption.fixedBasisPoints ?? min(max(customBasisPoints, 0), 10_000)
    }
}

// MARK: - 请假区间补录草稿

struct LeaveRangeEditorDraft: Equatable {
    var start: Date
    var end: Date
    var kind: LeaveKind
    var portion: LeavePortion
    var payOption: LeavePayOption
    var customBasisPoints: Int
    var note: String
    var workdaysOnly: Bool

    static func seed(start: Date = Date(), end: Date = Date()) -> LeaveRangeEditorDraft {
        let kind = LeaveKind.personal
        return LeaveRangeEditorDraft(
            start: start,
            end: end,
            kind: kind,
            portion: .fullDay,
            payOption: LeavePayOption.option(for: kind.defaultPayRatioBp),
            customBasisPoints: kind.defaultPayRatioBp,
            note: "",
            workdaysOnly: true
        )
    }

    var isSingleDay: Bool {
        DayKeyCoder.current.key(for: start) == DayKeyCoder.current.key(for: end)
    }

    /// 跨天时半天无处可落：提交时强制全天，预览也跟着走同一口径。
    var effectivePortion: LeavePortion { isSingleDay ? portion : .fullDay }

    var resolvedBasisPoints: Int {
        payOption.fixedBasisPoints ?? min(max(customBasisPoints, 0), 10_000)
    }

    var hasValidRange: Bool { end >= Calendar.current.startOfDay(for: start) }
}

// MARK: - 加班段调整草稿

struct OvertimeEditorDraft: Equatable {
    var start: Date
    var end: Date
    var kind: OvertimePayKind
    var multiplier: Int
    /// 基准时薪属于薪资派生数据，只在这里的内存里，保护期间不会渲染出去。
    var baseHourlyGross: Double
    var baseIsAuto: Bool

    static func seed(session: OvertimeSession?, now: Date = Date()) -> OvertimeEditorDraft {
        if let session {
            return OvertimeEditorDraft(
                start: session.start,
                end: session.end ?? session.start.addingTimeInterval(3600),
                kind: session.kind,
                multiplier: session.multiplier,
                baseHourlyGross: session.baseHourlyGross,
                // 既有段锁定当时的时薪快照，不随日期重价。
                baseIsAuto: false
            )
        }
        return OvertimeEditorDraft(
            start: now,
            end: now.addingTimeInterval(3600),
            kind: .paid,
            multiplier: 1,
            baseHourlyGross: 0,
            baseIsAuto: true
        )
    }
}

/// 草稿保留策略（纯常量，方便检查里直接引用）。
enum EditingDraftPolicy {
    /// 15 分钟：跨得开一次截图/屏幕共享，又不会长期留着一份半成品输入。
    static let maxAge: TimeInterval = 15 * 60
}

// MARK: - 草稿槽

/// 一个编辑器的草稿槽：同一次编辑的输入，加上"什么时候打开的"。
///
/// 复用规则：同一个 key 且在 `maxAge` 内打开 → 接着上次的草稿（保护打断后重新打开就靠这个）；
/// 换了目标或放太久 → 用调用方给的新种子，避免三天后又冒出旧草稿。
@MainActor
final class DraftSlot<Key: Hashable, Draft: Equatable>: ObservableObject {
    /// 默认 15 分钟：够跨一次截图/共享，又不至于长期留着一份半成品输入。
    @Published private(set) var key: Key?
    @Published private(set) var draft: Draft?
    private var updatedAt: Date

    var isOpen: Bool { key != nil }

    init(key: Key? = nil, draft: Draft? = nil, updatedAt: Date = Date()) {
        self.key = key
        self.draft = draft
        self.updatedAt = updatedAt
    }

    /// 打开编辑器：优先复用同目标、未过期的草稿，否则用 `seed`。
    @discardableResult
    func begin(_ key: Key, seed: Draft, now: Date = Date(),
               maxAge: TimeInterval = EditingDraftPolicy.maxAge) -> Draft {
        if self.key == key, let draft, now.timeIntervalSince(updatedAt) <= maxAge {
            return draft
        }
        self.key = key
        self.draft = seed
        updatedAt = now
        return seed
    }

    /// 编辑器每次改动都写回，保护来得及的时候最新输入就在草稿里。
    func update(_ newDraft: Draft, now: Date = Date()) {
        guard key != nil else { return }
        draft = newDraft
        updatedAt = now
    }

    /// 用户保存 / 删除 / 取消 / 完成，以及真正关窗：草稿清掉，保护结束不会自己弹回来。
    func close() {
        key = nil
        draft = nil
        updatedAt = .distantPast
    }
}

// MARK: - 汇总

/// 三个会丢输入的编辑器共用一份草稿存储（都是纯内存，不含落盘）。
@MainActor
final class EditingDraftStore: ObservableObject {
    let todayLeaveDay = DraftSlot<String, LeaveDayEditorDraft>()
    let leaveDay = DraftSlot<String, LeaveDayEditorDraft>()
    let leaveRange = DraftSlot<String, LeaveRangeEditorDraft>()
    let overtimeSession = DraftSlot<String, OvertimeEditorDraft>()

    init() {}

    /// 真正关窗（面板收起、设置窗口关闭）时统一清空。
    func closeAll() {
        todayLeaveDay.close()
        leaveDay.close()
        leaveRange.close()
        overtimeSession.close()
    }
}
