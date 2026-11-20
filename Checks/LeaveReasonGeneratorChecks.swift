import Foundation

@main
struct LeaveReasonGeneratorChecks {
    static func main() throws {
        var count = 0
        func expect(_ condition: Bool, _ message: String) {
            count += 1
            precondition(condition, message)
        }

        let catalog = LeaveReasonCatalog.all
        let ids = catalog.map(\.id)
        let keys = catalog.map(\.localizationKey)

        // 条目数量：20-30 条。
        expect((20...30).contains(catalog.count),
               "内置理由应在 20-30 条之间，实际 \(catalog.count)")

        // id / key 唯一、非空、前缀一致。
        expect(Set(ids).count == ids.count, "id 应唯一")
        expect(Set(keys).count == keys.count, "localizationKey 应唯一")
        expect(catalog.allSatisfy { !$0.id.isEmpty }, "id 不应为空")
        expect(catalog.allSatisfy { $0.localizationKey == "leaveReason.\($0.id)" },
               "key 应由 leaveReason. 前缀 + id 组成")
        expect(catalog.allSatisfy { !$0.defaultText.isEmpty }, "defaultText 不应为空")

        // key 集合应与 Hermes 定稿的 24 个 key 精确一致（防漂移）。
        let expectedKeys = Set(
            ["existential", "glitch", "time", "absurd"].flatMap { category in
                (1...6).map { "leaveReason.\(category).\($0)" }
            }
        )
        expect(Set(keys) == expectedKeys,
               "key 集合应与 Hermes 定稿的 24 个 key 精确一致")

        // 分类覆盖：四类都有条目，且目录恰好覆盖全部四类。
        for category in LeaveReasonCategory.allCases {
            expect(!LeaveReasonCatalog.reasons(in: category).isEmpty,
                   "分类 \(category.rawValue) 应有条目")
        }
        expect(Set(catalog.map(\.category)).count == LeaveReasonCategory.allCases.count,
               "目录应覆盖全部四个分类")

        // 连续不重复：seeded 生成器，每次排除上一条 id。
        var generator = LeaveReasonGenerator(seed: 0xC0FFEE)
        var previous: LeaveReason?
        for _ in 0..<200 {
            let reason = generator.generate(excluding: previous?.id)
            expect(ids.contains(reason.id), "生成结果应来自目录")
            if let previous {
                expect(reason.id != previous.id, "连续两次不应重复")
            }
            previous = reason
        }

        // 指定排除：排除一个固定 id，多次生成都不应命中它。
        var excludingGen = LeaveReasonGenerator(seed: 42)
        let excluded = catalog[0].id
        for _ in 0..<100 {
            let reason = excludingGen.generate(excluding: excluded)
            expect(reason.id != excluded, "指定排除的 id 不应被返回")
        }

        // 空排除：nil 与空串都不崩、都返回有效条目。
        var nilGen = LeaveReasonGenerator(seed: 7)
        for _ in 0..<50 {
            let reason = nilGen.generate(excluding: nil)
            expect(ids.contains(reason.id), "空排除(nil)应返回有效条目")
        }
        var emptyGen = LeaveReasonGenerator(seed: 8)
        for _ in 0..<50 {
            let reason = emptyGen.generate(excluding: "")
            expect(ids.contains(reason.id), "空排除(\"\")应返回有效条目")
        }

        // 随机范围不崩 + 分类覆盖：大量生成，各分类都被命中。
        var coverageGen = LeaveReasonGenerator(seed: 2024)
        var seen = Set<LeaveReasonCategory>()
        for _ in 0..<2000 {
            let reason = coverageGen.generate()
            expect(ids.contains(reason.id), "大量生成不应崩溃且都有效")
            seen.insert(reason.category)
        }
        expect(seen.count == LeaveReasonCategory.allCases.count,
               "随机生成应覆盖全部分类")

        // 可复现：相同 seed 产生相同序列。
        var a = LeaveReasonGenerator(seed: 123)
        var b = LeaveReasonGenerator(seed: 123)
        for _ in 0..<50 {
            expect(a.generate().id == b.generate().id, "相同 seed 应产生相同序列")
        }

        // 排除一个不存在的 id：不影响结果，照常返回有效条目。
        var junkGen = LeaveReasonGenerator(seed: 9)
        for _ in 0..<20 {
            let reason = junkGen.generate(excluding: "does.not.exist")
            expect(ids.contains(reason.id), "排除一个不存在的 id 应照常返回有效条目")
        }

        // 无 bundle 环境（Checks 二进制）下 localizedText 回退中文源串。
        expect(catalog[0].localizedText == catalog[0].defaultText,
               "无 bundle 时应回退到中文源串")

        print("\(count)/\(count) leave reason generator checks passed")
    }
}
