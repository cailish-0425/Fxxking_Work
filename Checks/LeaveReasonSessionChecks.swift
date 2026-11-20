import Foundation

/// 面板内“编个理由”会话的接线验证。
///
/// 生成器本身的随机/排除语义由 LeaveReasonGeneratorChecks 覆盖；这里验证
/// `LeaveReasonSession` 真的把状态留在会话里：连续抽取不重复、正文来自目录的
/// 本地化结果、同一个 seed 的两次会话产生同一序列（说明没有每次重建）。
@main
@MainActor
struct LeaveReasonSessionChecks {
    static func main() {
        var count = 0
        func expect(_ condition: Bool, _ message: String) {
            count += 1
            precondition(condition, message)
        }

        let catalog = LeaveReasonCatalog.all
        let byID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        let ids = Set(catalog.map(\.id))

        // 连续抽取：全部来自目录、正文非空且与 localizedText 一致、不连续重复。
        let session = LeaveReasonSession(seed: 0x5EED)
        var previous: String?
        var seen = Set<String>()
        for _ in 0..<200 {
            let suggestion = session.next()
            expect(ids.contains(suggestion.id), "会话返回的理由应来自目录")
            expect(!suggestion.text.isEmpty, "建议正文不能为空")
            expect(suggestion.text == byID[suggestion.id]?.localizedText,
                   "建议正文应与目录的 localizedText 一致")
            if let previous {
                expect(suggestion.id != previous, "连续两次抽取不应重复")
            }
            previous = suggestion.id
            seen.insert(suggestion.id)
        }
        expect(seen.count > 1, "会话应能产出不止一条理由")
        expect(seen.count <= catalog.count, "会话不应产出目录之外的理由")

        // 同 seed 可复现：两次独立会话产生完全相同的序列，证明生成器状态
        // 由会话持有，而不是每次抽取都重新播种。
        let first = LeaveReasonSession(seed: 99)
        let second = LeaveReasonSession(seed: 99)
        for _ in 0..<50 {
            let a = first.next()
            let b = second.next()
            expect(a == b, "同 seed 的会话应产生相同序列")
        }

        print("\(count)/\(count) leave reason session checks passed")
    }
}
