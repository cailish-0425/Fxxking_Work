import Foundation

/// 一条法定假日，只保留展示和计算需要的字段。
struct PublicHoliday: Codable, Hashable, Identifiable {
    let date: String
    let localName: String
    let name: String

    var id: String { "\(date)-\(name)" }

    var displayName: String {
        localName == name ? name : "\(localName) (\(name))"
    }
}
