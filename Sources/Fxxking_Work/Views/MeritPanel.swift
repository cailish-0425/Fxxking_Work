import SwiftUI

/// 功德系统的界面契约。
///
/// 骨架阶段由 `MeritSnapshot.mock` 提供占位数据。Claude Code 的 `MeritStore`
/// 实现后，把真实功德 / 等级 / 兑换状态映射成这个结构，视图层只换数据源。
struct MeritSnapshot: Equatable {
    /// 累计功德（对应 `MeritBalance.total`，跨天不清零）。
    var total: Double = 0
    /// 今日新增功德（计薪才涨，与木鱼同规则）。
    var todayPoints: Double = 0
    /// 当前等级。
    var level: MeritRank = .novice
    /// 兑换一张提前下班券要扣的功德。
    var redeemCost: Double = 100

    /// 下一级；扫地僧封顶时为 nil。
    var nextLevel: MeritRank? {
        let all = MeritRank.allCases
        guard let index = all.firstIndex(of: level), index + 1 < all.count else { return nil }
        return all[index + 1]
    }

    /// 当前等级内已积累的功德。
    var pointsInLevel: Double { max(total - level.threshold, 0) }

    /// 升到下一级所需的等级内功德。
    var pointsForNextLevel: Double {
        guard let next = nextLevel else { return 0 }
        return next.threshold - level.threshold
    }

    /// 距下一级还差多少功德。
    var pointsToNextLevel: Double { max(pointsForNextLevel - pointsInLevel, 0) }

    /// 当前等级内的进度（0...1），封顶时为 1。
    var progressFraction: Double {
        guard nextLevel != nil, pointsForNextLevel > 0 else { return 1 }
        return min(max(pointsInLevel / pointsForNextLevel, 0), 1)
    }
}

extension MeritSnapshot {
    /// 骨架阶段的占位数据，接入真实 `MeritStore` 后删除。
    static let mock = MeritSnapshot(
        total: 25_000,
        todayPoints: 3_600,
        level: .arhat,
        redeemCost: 500
    )
}

/// 功德区：等级外观 + 功德槽 + 兑换按钮占位。
///
/// 纯展示视图，只吃一个快照。兑换按钮暂时弹"待实现"提示，接 `MeritStore` 后换成真实动作。
struct MeritPanel: View {
    let snapshot: MeritSnapshot

    @State private var showRedeemTodo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            MeritSlot(fraction: snapshot.progressFraction, tint: snapshot.level.meritTint)
            detail
            redeemButton
        }
        .padding(10)
        .background(snapshot.level.meritTint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .alert(Loc.t("merit.redeem.todo"), isPresented: $showRedeemTodo) {
            Button(Loc.t("merit.redeem.todo.ok"), role: .cancel) {}
        }
    }

    // MARK: - 等级外观

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: snapshot.level.meritIcon)
                Text(snapshot.level.meritTitle)
                    .font(.caption)
                    .bold()
            }
            .foregroundStyle(snapshot.level.meritTint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(snapshot.level.meritTint.opacity(0.15), in: Capsule())

            Spacer(minLength: 4)

            if snapshot.todayPoints > 0 {
                Text(Loc.t("merit.today", meritPoints(snapshot.todayPoints)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - 功德槽与明细

    private var detail: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Loc.t("merit.progress", meritPoints(snapshot.pointsInLevel), meritPoints(snapshot.pointsForNextLevel)))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: 4)
            if let next = snapshot.nextLevel {
                Text(Loc.t("merit.awayFromNext", meritPoints(snapshot.pointsToNextLevel), next.meritTitle))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - 兑换按钮占位

    private var redeemButton: some View {
        Button {
            // TODO: 接 MeritStore 后换成真实兑换动作。
            showRedeemTodo = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "ticket")
                Text(Loc.t("merit.redeem", meritPoints(snapshot.redeemCost)))
                Spacer(minLength: 0)
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .background(snapshot.level.meritTint.opacity(0.18), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .foregroundStyle(snapshot.level.meritTint)
        .help(Loc.t("merit.redeem.help"))
    }
}

/// 功德点数按整数显示，带千分位，locale 跟随 `Loc.locale`。
private func meritPoints(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0)).locale(Loc.locale))
}

/// `MeritRank` 的展示信息（图标 / 配色 / 文案）。
///
/// 放在视图层而不是 `Support/DisplayNames.swift`，是为了不跟 Claude Code
/// 正在写的 Support 层抢文件；词库定稿后可以整体挪过去。
private extension MeritRank {
    /// 等级展示名，由低到高：沙弥 → 罗汉 → 扫地僧。
    var meritTitle: String {
        switch self {
        case .novice: return Loc.t("merit.level.novice")
        case .arhat: return Loc.t("merit.level.arhat")
        case .sweepingMonk: return Loc.t("merit.level.sweeper")
        }
    }

    /// SF Symbol，跟等级气质对齐：一叶（初入门）→ 星光（有所成）→ 王冠（深藏不露）。
    var meritIcon: String {
        switch self {
        case .novice: return "leaf.fill"
        case .arhat: return "sparkles"
        case .sweepingMonk: return "crown.fill"
        }
    }

    /// 每个等级一个主题色，木色系由浅入深，和木鱼的配色呼应。
    var meritTint: Color {
        switch self {
        case .novice: return Color(red: 0.60, green: 0.62, blue: 0.55)
        case .arhat: return Color(red: 0.85, green: 0.69, blue: 0.36)
        case .sweepingMonk: return Color(red: 0.72, green: 0.36, blue: 0.18)
        }
    }
}

/// 功德槽：一条横向胶囊，功德向下一级推进多少就亮多少。
private struct MeritSlot: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(tint.gradient)
                    .frame(width: max(geo.size.width * min(max(fraction, 0), 1), 2))
            }
        }
        .frame(height: 8)
    }
}
