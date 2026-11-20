import Foundation

/// 语言基础设施的独立断言：新增 ja/ko 后，既有设置值解码、locale 组装和资源边界
/// 都要有可重复的验证。`Checks/main.swift` 只覆盖“所有 case 都能切”，这里补上
/// “老值不变、新值可用、资源没落地时明确 SKIP”。
@main
struct LocalizationChecks {
    static func main() {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            precondition(condition, message)
        }

        // MARK: 选项表

        expect(
            AppLanguage.allCases.map(\.rawValue) == [
                "system", "english", "simplifiedChinese", "french",
                "russian", "spanish", "japanese", "korean",
            ],
            "新语言必须追加在末尾，已有 case 顺序和 rawValue 不能变"
        )

        let codes = AppLanguage.allCases.compactMap(\.localizationCode)
        expect(code(AppLanguage.japanese) == "ja", "日语应映射到 ja.lproj")
        expect(code(AppLanguage.korean) == "ko", "韩语应映射到 ko.lproj")
        expect(Set(codes).count == codes.count, "语言代码不能重复")
        expect(code(.system) == nil, "跟随系统不映射到具体 .lproj")

        // 自称一律用母语写法，切错语言时还能找回来。
        expect(AppLanguage.japanese.nativeName == "日本語", "日语自称应为 日本語")
        expect(AppLanguage.korean.nativeName == "한국어", "韩语自称应为 한국어")

        // MARK: Codable 兼容

        // 老配置里的 rawValue 是 case 名，不是 ISO 码；新增 case 不能改它们。
        let legacy: [(String, AppLanguage)] = [
            ("system", .system),
            ("english", .english),
            ("simplifiedChinese", .simplifiedChinese),
            ("french", .french),
            ("russian", .russian),
            ("spanish", .spanish),
        ]
        for (raw, expected) in legacy {
            expect(decodeLanguage(raw) == expected, "旧设置值 \(raw) 应继续解码为 \(expected.rawValue)")
        }

        for language in [AppLanguage.japanese, .korean] {
            expect(decodeLanguage(language.rawValue) == language, "新设置值 \(language.rawValue) 应可解码")
            let roundTrip = try? JSONDecoder().decode(
                AppLanguage.self,
                from: JSONEncoder().encode(language)
            )
            expect(roundTrip == language, "\(language.rawValue) 应编码再解码一致")
        }

        // Configuration 对未知语言走宽松回退，不因为未来值或手改文件而丢整份配置。
        let unknown = #"{"language":"german","salaryAmount":10000}"#
        let unknownConfig = try? JSONDecoder().decode(
            Configuration.self,
            from: Data(unknown.utf8)
        )
        expect(unknownConfig?.language == .system, "未知语言应回退为跟随系统")
        expect(unknownConfig?.salaryAmount == 10000, "语言回退不能连累同份配置的其他字段")

        let legacyConfig = #"{"language":"english","salaryAmount":10000}"#
        let legacyDecoded = try? JSONDecoder().decode(
            Configuration.self,
            from: Data(legacyConfig.utf8)
        )
        expect(legacyDecoded?.language == .english, "旧配置里的 english 应保持英文选择")

        let newConfig = #"{"language":"korean","salaryAmount":10000}"#
        let newDecoded = try? JSONDecoder().decode(
            Configuration.self,
            from: Data(newConfig.utf8)
        )
        expect(newDecoded?.language == .korean, "新配置里的 korean 应解为韩语")

        // MARK: Locale 组装

        let systemRegion = Locale.current.region

        for (language, expected) in [(AppLanguage.japanese, "ja"), (.korean, "ko")] {
            Loc.select(language)
            expect(Loc.language == language, "Loc.language 应切到 \(language.rawValue)")
            expect(
                Loc.locale.language.languageCode?.identifier == expected,
                "\(expected) 的 locale 语言码不对：\(Loc.locale.identifier)"
            )
            // 只换语言/字形，地区必须保持系统值，否则金额、日期格式会跟着跑偏。
            expect(Loc.locale.region == systemRegion, "切到 \(expected) 不能改变地区")
        }

        Loc.select(.system)
        expect(Loc.language == .system, "Loc.select(.system) 应回到跟随系统")
        expect(Loc.locale == Locale.current, "跟随系统时应直接使用 Locale.current")

        // MARK: 资源边界

        // 检查可执行文件不在 app bundle 里，Bundle.main 找不到 Resources；直接按
        // 源码位置读仓库里的 .lproj。资源未落地时明确 SKIP，而不是把“还没翻译”
        // 当成代码失败——日/韩文件由资源负责人交付。
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        for expectedCode in ["ja", "ko"] {
            let lproj = repoRoot
                .appendingPathComponent("Resources")
                .appendingPathComponent("\(expectedCode).lproj")
            guard FileManager.default.fileExists(atPath: lproj.path) else {
                print("SKIP  [\(expectedCode)] Resources/\(expectedCode).lproj 尚未落地；只验证代码映射，翻译覆盖留给 check-localization.py")
                continue
            }
            guard let bundle = Bundle(path: lproj.path) else {
                expect(false, "\(expectedCode).lproj 存在但 Bundle 无法加载")
                continue
            }
            let marker = "\u{0}missing"
            let sample = bundle.localizedString(
                forKey: "language.followSystem",
                value: marker,
                table: nil
            )
            expect(sample != marker, "\(expectedCode).lproj 已落地，应至少包含 language.followSystem")
            expect(!sample.isEmpty, "\(expectedCode) 的示例文案不能为空")
        }

        print("\(checks)/\(checks) localization checks passed")
    }

    private static func code(_ language: AppLanguage) -> String? {
        language.localizationCode
    }

    private static func decodeLanguage(_ raw: String) -> AppLanguage? {
        try? JSONDecoder().decode(AppLanguage.self, from: Data("\"\(raw)\"".utf8))
    }
}
