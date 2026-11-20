import Foundation

/// 菜单栏弹窗的生命周期内保存一份可变生成器，并把最近一条 id 传给下一次抽取，
/// 避免 UI 每次重建时都从头开始或连续返回同一句。
@MainActor
final class LeaveReasonSession: ObservableObject {
    private var generator: LeaveReasonGenerator
    private var lastReasonID: String?

    init(seed: UInt64 = SeededGenerator.randomSeed()) {
        generator = LeaveReasonGenerator(seed: seed)
    }

    func next() -> LeaveReasonSuggestion {
        let reason = generator.generate(excluding: lastReasonID)
        lastReasonID = reason.id
        return LeaveReasonSuggestion(id: reason.id, text: reason.localizedText)
    }
}
