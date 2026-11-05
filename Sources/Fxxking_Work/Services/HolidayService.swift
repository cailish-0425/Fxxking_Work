import Foundation

/// 某一年的假日数据还会不会变。
///
/// 年份过完之后官方安排就定死了，本地存过就永远不必再联网。当年和次年都还会动：
/// 次年的调休安排往往要到前一年年底官方才公布，在那之前数据源里通常只有节日日期、
/// 一个补班日都没有，把它当成最终数据缓存下来会让整年的工作日算错。
enum HolidayYearPolicy: Equatable {
    /// 年份已经过去，有本地副本就直接用，不发请求。
    case frozen
    /// 还可能被改，带 ETag 去校验；内容没变服务端回 304，零字节。
    case revalidate

    static func of(year: Int, now: Date, calendar: Calendar = .current) -> HolidayYearPolicy {
        year < calendar.component(.year, from: now) ? .frozen : .revalidate
    }
}

/// 拉取法定假日并落盘缓存，断网时退回到缓存。数据来自 github.com/wrfly/holidays，
/// 一年一个文件，各自带 ETag 单独缓存。
@MainActor
final class HolidayService: ObservableObject {
    enum Status: Equatable {
        case idle
        case loading
        case loaded(fromCache: Bool)
        case unsupportedCountry
        case failed(String)
    }

    struct Request: Equatable {
        var countryCode: String
        var includeRegional: Bool
        var years: [Int]
    }

    /// 假期和调休合成一个值发布：分成两个 @Published 的话订阅方会收到一次
    /// 新假期配旧调休的中间状态，白重算一遍。
    struct Dataset: Equatable {
        var holidays: [String: PublicHoliday] = [:]
        /// 数据源标出来的调休上班日，例如中国春节前后被挪成工作日的那几个周末。
        var makeupWorkdays: Set<String> = []
    }

    @Published private(set) var dataset = Dataset()
    @Published private(set) var status: Status = .idle
    @Published private(set) var lastUpdated: Date?

    var holidays: [String: PublicHoliday] { dataset.holidays }
    var makeupWorkdays: Set<String> { dataset.makeupWorkdays }

    private var inFlight: Request?
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
        Self.migrateLegacyCacheIfNeeded()
        Self.removeLegacyCacheFiles()
    }

    var holidayDates: Set<String> { Set(holidays.keys) }

    func holiday(on dayKey: String) -> PublicHoliday? { holidays[dayKey] }

    func upcoming(from dayKey: String, limit: Int = 5) -> [PublicHoliday] {
        holidays.values
            .filter { $0.date >= dayKey }
            .sorted { $0.date < $1.date }
            .prefix(limit)
            .map { $0 }
    }

    func load(_ request: Request, force: Bool = false) async {
        if !force, inFlight == request { return }
        inFlight = request
        status = .loading

        let outcome = await collect(request, force: force)

        guard !outcome.csvByYear.isEmpty else {
            clear()
            // 一个年份都没拿到。全是 404 说明数据源没收录这个国家，
            // 否则是网络的问题，得把原因显示出来而不是赖用户选错国家。
            if let error = outcome.lastError, outcome.missingYears < request.years.count {
                status = .failed(error.localizedDescription)
            } else {
                status = .unsupportedCountry
            }
            return
        }

        var parsed = GitHubHolidaysSource.Parsed()
        for (_, csv) in outcome.csvByYear.sorted(by: { $0.key < $1.key }) {
            let piece = GitHubHolidaysSource.parse(csv: csv, includeRegional: request.includeRegional)
            parsed.holidays.append(contentsOf: piece.holidays)
            parsed.makeupWorkdays.formUnion(piece.makeupWorkdays)
        }
        parsed.holidays.sort { $0.date < $1.date }

        apply(parsed, fromCache: !outcome.reachedServer)
    }

    private func apply(_ parsed: GitHubHolidaysSource.Parsed, fromCache: Bool) {
        dataset = Dataset(
            holidays: Dictionary(parsed.holidays.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first }),
            makeupWorkdays: parsed.makeupWorkdays
        )
        lastUpdated = Date()
        status = parsed.holidays.isEmpty ? .unsupportedCountry : .loaded(fromCache: fromCache)
    }

    private func clear() {
        dataset = Dataset()
    }

    // MARK: - 拉取

    private struct Outcome {
        var csvByYear: [Int: String] = [:]
        /// 数据源里没有这一年的文件，不算失败：次年的数据本来就可能还没录入。
        var missingYears = 0
        /// 这轮有没有真的问到服务器。全程走本地时状态栏要标明是缓存。
        var reachedServer = false
        var lastError: Error?
    }

    /// 逐年取数据。已经过去的年份直接吃本地副本；其余年份带 ETag 校验，
    /// 内容没变服务端回 304、零字节，所以可以放心每次启动都校验一遍。
    private func collect(_ request: Request, force: Bool) async -> Outcome {
        var outcome = Outcome()
        let now = Date()

        for year in request.years {
            let cached = readCache(countryCode: request.countryCode, year: year)

            if !force, HolidayYearPolicy.of(year: year, now: now) == .frozen, let cached {
                outcome.csvByYear[year] = cached.csv
                continue
            }

            guard let url = GitHubHolidaysSource.fileURL(countryCode: request.countryCode, year: year) else {
                outcome.missingYears += 1
                continue
            }

            do {
                // 手动刷新时不带 ETag，强制把整份内容重新拉一遍。
                switch try await conditionalGet(url, etag: force ? nil : cached?.etag) {
                case .notModified:
                    outcome.reachedServer = true
                    if let cached { outcome.csvByYear[year] = cached.csv }
                case .payload(let csv, let etag):
                    outcome.reachedServer = true
                    writeCache(countryCode: request.countryCode, year: year, csv: csv, etag: etag)
                    outcome.csvByYear[year] = csv
                }
            } catch HolidayError.unsupportedCountry {
                // 这一年还没录入。以前存过就先用旧的，总比当作没有假期强。
                if let cached {
                    outcome.csvByYear[year] = cached.csv
                } else {
                    outcome.missingYears += 1
                }
            } catch {
                outcome.lastError = error
                if let cached { outcome.csvByYear[year] = cached.csv }
            }
        }

        return outcome
    }

    private enum Fetched {
        case notModified
        case payload(csv: String, etag: String?)
    }

    private func conditionalGet(_ url: URL, etag: String?) async throws -> Fetched {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        // 绕开 URLSession 自己那层缓存，否则它可能替我们把 304 消化成 200，
        // 我们就分不清内容到底变没变，也就白搭了 ETag。
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HolidayError.badResponse }

        switch http.statusCode {
        case 304:
            return .notModified
        case 404:
            throw HolidayError.unsupportedCountry
        case 200:
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                throw HolidayError.badResponse
            }
            return .payload(csv: text, etag: http.value(forHTTPHeaderField: "ETag"))
        default:
            throw HolidayError.httpStatus(http.statusCode)
        }
    }

    private static let userAgent = "Fxxking_Work/1.0 (maintained by cailish-0425)"

    // MARK: - 缓存

    private struct CachedYear: Codable {
        var savedAt: Date
        var etag: String?
        var csv: String
    }

    private static func cacheDirectory() -> URL {
        let base =
            FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Fxxking_Work/holidays", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 改名前的旧缓存目录 `Application Support/ILoveMyJob/holidays`。
    /// 只把其中还没复制过来的年份缓存迁到新目录，旧数据原样保留不删。
    private static func migrateLegacyCacheIfNeeded() {
        let base =
            FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let legacy = base.appendingPathComponent("ILoveMyJob/holidays", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)) ?? []
        guard !files.isEmpty else { return }
        let target = cacheDirectory()
        for file in files where file.pathExtension == "json" {
            let dest = target.appendingPathComponent(file.lastPathComponent)
            if !FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.copyItem(at: file, to: dest)
            }
        }
    }

    private func cacheURL(countryCode: String, year: Int) -> URL {
        Self.cacheDirectory().appendingPathComponent("\(countryCode)-\(year).json")
    }

    private func readCache(countryCode: String, year: Int) -> CachedYear? {
        guard let data = try? Data(contentsOf: cacheURL(countryCode: countryCode, year: year)) else { return nil }
        return try? JSONDecoder().decode(CachedYear.self, from: data)
    }

    private func writeCache(countryCode: String, year: Int, csv: String, etag: String?) {
        let payload = CachedYear(savedAt: Date(), etag: etag, csv: csv)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: cacheURL(countryCode: countryCode, year: year), options: .atomic)
    }

    /// 旧版本的缓存文件名里带着「国家-范围-年份跨度」，每跨一年就换一个名字，
    /// 旧的那批再没人读却一直躺在磁盘上。升级时顺手清掉。
    private static func removeLegacyCacheFiles() {
        let dir = cacheDirectory()
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("github-") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private enum HolidayError: LocalizedError {
        case badResponse
        case httpStatus(Int)
        case unsupportedCountry

        var errorDescription: String? {
            switch self {
            case .badResponse: return Loc.t("error.badResponse")
            case .httpStatus(let code): return Loc.t("error.httpStatus", code)
            case .unsupportedCountry: return Loc.t("error.unsupportedCountry")
            }
        }
    }
}
