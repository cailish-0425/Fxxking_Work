import Foundation

/// 请假理由分类。故意保持抽象、戏谑，不指向任何真实医疗或法律情形，
/// 也不伪装成正式病假证明——一眼就能看出是玩笑。
enum LeaveReasonCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 存在主义
    case existential
    /// 系统故障
    case glitch
    /// 时间管理
    case time
    /// 荒诞日常
    case absurd

    var id: String { rawValue }
}

/// 一条本地请假理由。文案不直接进 view：view 通过 `Loc.t(localizationKey)` 取值。
/// `defaultText` 是中文源串，供写入 `Resources/zh-Hans.lproj/Localizable.strings`
/// 并作为缺键时的回退，二者保持同步即可。
struct LeaveReason: Identifiable, Equatable, Sendable {
    /// 稳定标识，如 "existential.1"；也是 `generate(excluding:)` 用来去重的值。
    let id: String
    let category: LeaveReasonCategory
    /// 本地化 key，形如 "leaveReason.existential.1"。
    let localizationKey: String
    /// 中文源串（默认文案）。
    let defaultText: String
}

extension LeaveReason {
    /// 由 id 推导 key 的便捷构造，目录里用它避免手写重复前缀。
    init(id: String, category: LeaveReasonCategory, defaultText: String) {
        self.id = id
        self.category = category
        self.localizationKey = "leaveReason.\(id)"
        self.defaultText = defaultText
    }

    /// view 取值入口：优先 `Loc.t(localizationKey)`；key 没打进 bundle 时
    /// `Loc.t` 会原样返回 key，这里就回退到中文源串，保证无 bundle 环境也能显示。
    var localizedText: String {
        let value: String
        switch localizationKey {
        case "leaveReason.existential.1": value = Loc.t("leaveReason.existential.1")
        case "leaveReason.existential.2": value = Loc.t("leaveReason.existential.2")
        case "leaveReason.existential.3": value = Loc.t("leaveReason.existential.3")
        case "leaveReason.existential.4": value = Loc.t("leaveReason.existential.4")
        case "leaveReason.existential.5": value = Loc.t("leaveReason.existential.5")
        case "leaveReason.existential.6": value = Loc.t("leaveReason.existential.6")
        case "leaveReason.glitch.1": value = Loc.t("leaveReason.glitch.1")
        case "leaveReason.glitch.2": value = Loc.t("leaveReason.glitch.2")
        case "leaveReason.glitch.3": value = Loc.t("leaveReason.glitch.3")
        case "leaveReason.glitch.4": value = Loc.t("leaveReason.glitch.4")
        case "leaveReason.glitch.5": value = Loc.t("leaveReason.glitch.5")
        case "leaveReason.glitch.6": value = Loc.t("leaveReason.glitch.6")
        case "leaveReason.time.1": value = Loc.t("leaveReason.time.1")
        case "leaveReason.time.2": value = Loc.t("leaveReason.time.2")
        case "leaveReason.time.3": value = Loc.t("leaveReason.time.3")
        case "leaveReason.time.4": value = Loc.t("leaveReason.time.4")
        case "leaveReason.time.5": value = Loc.t("leaveReason.time.5")
        case "leaveReason.time.6": value = Loc.t("leaveReason.time.6")
        case "leaveReason.absurd.1": value = Loc.t("leaveReason.absurd.1")
        case "leaveReason.absurd.2": value = Loc.t("leaveReason.absurd.2")
        case "leaveReason.absurd.3": value = Loc.t("leaveReason.absurd.3")
        case "leaveReason.absurd.4": value = Loc.t("leaveReason.absurd.4")
        case "leaveReason.absurd.5": value = Loc.t("leaveReason.absurd.5")
        case "leaveReason.absurd.6": value = Loc.t("leaveReason.absurd.6")
        default: value = localizationKey
        }
        return value == localizationKey ? defaultText : value
    }
}

/// 内置理由目录。纯本地数据，不调用网络或任何 AI 服务。
enum LeaveReasonCatalog {
    /// 24 条，四类各 6 条。key 与 Hermes 定稿一致：
    /// leaveReason.existential.1…6 / glitch.1…6 / time.1…6 / absurd.1…6。
    static let all: [LeaveReason] = [
        // 存在主义
        LeaveReason(id: "existential.1", category: .existential,
                    defaultText: "需要确认自己是否还存在于这个坐标系里。"),
        LeaveReason(id: "existential.2", category: .existential,
                    defaultText: "今日的存在感余额不足，需要离线补一下。"),
        LeaveReason(id: "existential.3", category: .existential,
                    defaultText: "灵魂和工位的时差还没倒过来。"),
        LeaveReason(id: "existential.4", category: .existential,
                    defaultText: "想在周中认真回答一次「我是谁」。"),
        LeaveReason(id: "existential.5", category: .existential,
                    defaultText: "意义暂时断供，申请外出寻找。"),
        LeaveReason(id: "existential.6", category: .existential,
                    defaultText: "给「为什么要上班」这个命题放一天假。"),

        // 系统故障
        LeaveReason(id: "glitch.1", category: .glitch,
                    defaultText: "生物钟与公司日历发生版本冲突。"),
        LeaveReason(id: "glitch.2", category: .glitch,
                    defaultText: "睡眠子系统昨夜崩溃，今天正在回滚。"),
        LeaveReason(id: "glitch.3", category: .glitch,
                    defaultText: "咖啡因驱动今天拒绝启动。"),
        LeaveReason(id: "glitch.4", category: .glitch,
                    defaultText: "肉身发布了不可回滚的更新，需要重启。"),
        LeaveReason(id: "glitch.5", category: .glitch,
                    defaultText: "情绪缓存溢出，正在清理。"),
        LeaveReason(id: "glitch.6", category: .glitch,
                    defaultText: "注意力模块今天离线维护。"),

        // 时间管理
        LeaveReason(id: "time.1", category: .time,
                    defaultText: "需要把昨天欠的觉分期补回来。"),
        LeaveReason(id: "time.2", category: .time,
                    defaultText: "把「明天再说」提前到了今天。"),
        LeaveReason(id: "time.3", category: .time,
                    defaultText: "今天的日程被一个漫长的梦占用了。"),
        LeaveReason(id: "time.4", category: .time,
                    defaultText: "需要用一整天来对齐我的时间线。"),
        LeaveReason(id: "time.5", category: .time,
                    defaultText: "日程表里出现了一个无法解释的空洞。"),
        LeaveReason(id: "time.6", category: .time,
                    defaultText: "申请把今天调成「弹性存在」。"),

        // 荒诞日常
        LeaveReason(id: "absurd.1", category: .absurd,
                    defaultText: "猫把通勤鞋藏了起来，且拒绝谈判。"),
        LeaveReason(id: "absurd.2", category: .absurd,
                    defaultText: "邻居的装修声让我相信今天就是末日。"),
        LeaveReason(id: "absurd.3", category: .absurd,
                    defaultText: "要在家等一个「今天下午一定到」的快递。"),
        LeaveReason(id: "absurd.4", category: .absurd,
                    defaultText: "早上的煎蛋形状预示今日不宜久坐。"),
        LeaveReason(id: "absurd.5", category: .absurd,
                    defaultText: "洗衣机吞了一只袜子，需要全程看守营救。"),
        LeaveReason(id: "absurd.6", category: .absurd,
                    defaultText: "电梯今天看我的眼神不对劲。"),
    ]

    static func reasons(in category: LeaveReasonCategory) -> [LeaveReason] {
        all.filter { $0.category == category }
    }
}

/// SplitMix64：可复现的确定性伪随机数生成器。系统 RNG 不能设种子，
/// 这里内置一个极简实现，让 Checks 用固定 seed 复现同一条序列。
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    /// 从系统熵取一个种子，供默认构造用（每次启动序列不同）。
    static func randomSeed() -> UInt64 {
        var system = SystemRandomNumberGenerator()
        return system.next()
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// 本地请假理由生成器：从内置目录随机取一条，避开上一条（`excluding`）。
/// 纯值类型，持有可复现的 RNG；view/控制器里存一份，调用 `generate` 推进即可。
struct LeaveReasonGenerator {
    private var rng: SeededGenerator

    /// 不传 seed 时用系统熵（每次启动序列不同）；传固定 seed 可复现（Checks 用）。
    init(seed: UInt64 = SeededGenerator.randomSeed()) {
        rng = SeededGenerator(seed: seed)
    }

    /// 随机取一条，避开 `excluding` 对应的 `id`（用于避免连续重复）。
    /// 传 nil 或空串表示不排除；排除后候选集为空时回退到全目录，保证不崩。
    @discardableResult
    mutating func generate(excluding: String? = nil) -> LeaveReason {
        var pool = LeaveReasonCatalog.all
        if let excluding, !excluding.isEmpty {
            let filtered = pool.filter { $0.id != excluding }
            if !filtered.isEmpty { pool = filtered }
        }
        return pool[Int(rng.next() % UInt64(pool.count))]
    }
}
