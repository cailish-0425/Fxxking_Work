/// 界面语言。和地区分开：改语言不应该顺带把货币、数字、日期格式也改掉，
/// 一个在中国上班的人把界面切成英文，金额还是该按本地习惯显示。
import Foundation

/// 带语言覆盖能力的字符串查找。
///
/// 查找发生在应用的每一层，包括断言程序里不在主线程跑的算钱逻辑，
/// 所以当前语言放在锁后面而不是绑定到某个 actor 上。

/// 联合国六种官方语言里的五种。缺阿拉伯语，它需要 RTL 布局，是另一件事。
enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case english
    case simplifiedChinese
    case french
    case russian
    case spanish

    var id: String { rawValue }

    /// Resources 下 .lproj 目录的名字，nil 表示跟随系统。
    var localizationCode: String? {
        switch self {
        case .system: return nil
        case .english: return "en"
        case .simplifiedChinese: return "zh-Hans"
        case .french: return "fr"
        case .russian: return "ru"
        case .spanish: return "es"
        }
    }

    /// 一律用该语言自己的写法。用户如果误切到看不懂的语言，
    /// 还得靠这一列在选择器里找回自己的母语。
    var nativeName: String {
        switch self {
        case .system: return Loc.t("language.followSystem")
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        case .french: return "Français"
        case .russian: return "Русский"
        case .spanish: return "Español"
        }
    }
}
enum Loc {
    private static let state = State()

    static var language: AppLanguage { state.snapshot.language }

    /// 用于货币、百分比、时长这类格式化。
    static var locale: Locale { state.snapshot.locale }

    /// 带上界面语言的日历，取星期名和月份名时用它。
    static var calendar: Calendar { state.snapshot.calendar }

    static func select(_ language: AppLanguage) {
        state.select(language)
    }

    static func t(_ key: String) -> String {
        state.snapshot.string(key)
    }

    /// 参数版。传了 locale，`.stringsdict` 里的复数规则才会被展开。
    static func t(_ key: String, _ arguments: any CVarArg...) -> String {
        let snapshot = state.snapshot
        return String(format: snapshot.string(key), locale: snapshot.locale, arguments: arguments)
    }
}
extension Loc {
    /// 语言、bundle、locale 一起换，避免出现「英文文案配中文格式」这种半截状态。
    fileprivate struct Snapshot {
        /// CFBundle 找不到 key 时会原样返回 value，用一个不可能出现的串当哨兵。
        private static let missing = "\u{0}Fxxking_Work.missingKey"

        let language: AppLanguage
        let locale: Locale
        let calendar: Calendar
        let bundle: Bundle
        /// 英文是源语言，没翻的条目一律回退到它。
        let english: Bundle?

        init(language: AppLanguage) {
            self.language = language
            self.locale = Self.resolveLocale(for: language)
            self.bundle = Self.resolveBundle(for: language.localizationCode) ?? .main
            self.english = Self.resolveBundle(for: "en")

            var calendar = Calendar.current
            calendar.locale = locale
            self.calendar = calendar
        }

        func string(_ key: String) -> String {
            let value = bundle.localizedString(forKey: key, value: Self.missing, table: nil)
            if value != Self.missing { return value }
            if let english, english !== bundle {
                let fallback = english.localizedString(forKey: key, value: Self.missing, table: nil)
                if fallback != Self.missing { return fallback }
            }
            // 键名本身。资源没打进 bundle 时界面会显示成 key，是个足够响亮的失败信号。
            return key
        }

        private static func resolveLocale(for language: AppLanguage) -> Locale {
            guard let code = language.localizationCode else { return .current }
            // 只替换语言码和字形，地区、日历、度量衡一律留给系统。
            // 整个换掉 languageComponents 会把地区一起冲掉，中国用户切成英文之后
            // 金额就会变成 CN¥1,234.50 而不是 ¥1,234.50。
            let target = Locale.Language(identifier: code)
            var components = Locale.Components(locale: .current)
            components.languageComponents.languageCode = target.languageCode
            components.languageComponents.script = target.script
            return Locale(components: components)
        }

        private static func resolveBundle(for code: String?) -> Bundle? {
            guard let code else { return .main }
            guard let path = Bundle.main.path(forResource: code, ofType: "lproj") else { return nil }
            return Bundle(path: path)
        }
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Snapshot(language: .system)

        var snapshot: Snapshot {
            lock.lock()
            defer { lock.unlock() }
            return current
        }

        func select(_ language: AppLanguage) {
            lock.lock()
            defer { lock.unlock() }
            guard current.language != language else { return }
            current = Snapshot(language: language)
        }
    }
}
