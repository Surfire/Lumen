import Combine
import Foundation

struct CurrencyRateSnapshot: Codable, Sendable, Equatable {
    let base: String
    let rates: [String: Double]
    let updatedDate: String
    let fetchedAt: Date
    let isFallback: Bool

    init(base: String = "USD", rates: [String: Double], updatedDate: String, fetchedAt: Date, isFallback: Bool) {
        self.base = base
        self.rates = rates
        self.updatedDate = updatedDate
        self.fetchedAt = fetchedAt
        self.isFallback = isFallback
    }

    static let fallback = CurrencyRateSnapshot(
        base: "USD",
        rates: [
            "USD": 1.0,
            "CNY": 7.24,
            "HKD": 7.78,
            "TWD": 32.50,
            "MOP": 8.01,
            "JPY": 154.50,
            "EUR": 0.95,
            "GBP": 0.79,
            "KRW": 1405.0,
            "SGD": 1.34,
            "AUD": 1.54,
            "CAD": 1.40,
            "CHF": 0.88,
            "NZD": 1.70,
            "INR": 84.40,
            "THB": 34.60,
            "MYR": 4.46,
            "VND": 25380.0,
            "PHP": 58.70,
            "IDR": 15850.0,
            "RUB": 100.0,
            "BRL": 5.80,
            "MXN": 20.30,
            "SEK": 10.90,
            "NOK": 11.05,
            "DKK": 7.08,
            "PLN": 4.10,
            "TRY": 34.50,
            "ZAR": 18.10,
            "AED": 3.6725,
            "SAR": 3.75,
        ],
        updatedDate: "Built-in",
        fetchedAt: .distantPast,
        isFallback: true
    )

    func convert(_ amount: Double, from: String, to: String) -> Double? {
        guard amount.isFinite else { return nil }
        let fromCode = from.uppercased()
        let toCode = to.uppercased()
        guard let fromRate = rates[fromCode], fromRate.isFinite, fromRate > 0,
              let toRate = rates[toCode], toRate.isFinite, toRate > 0 else {
            return nil
        }
        let converted = (amount / fromRate) * toRate
        guard converted.isFinite else { return nil }
        return converted
    }
}

enum CurrencyRateError: LocalizedError, Equatable {
    case responseTooLarge
    case badHTTPStatus(Int)
    case invalidPayload
    case missingRequiredRates

    var errorDescription: String? {
        switch self {
        case .responseTooLarge: return "Currency rate response exceeded 256 KB limit."
        case .badHTTPStatus(let code): return "Currency rate server returned HTTP \(code)."
        case .invalidPayload: return "Currency rate response is not valid JSON."
        case .missingRequiredRates: return "Currency rate response is missing required baseline rates."
        }
    }
}

@MainActor
final class CurrencyRateStore: ObservableObject {
    typealias Fetcher = @Sendable (URL) async throws -> Data

    nonisolated static let autoRefreshDefaultsKey = "lumen.currencyAutoRefresh"
    nonisolated static let endpointURL = URL(string: "https://open.er-api.com/v6/latest/USD")!
    nonisolated static let maxResponseBytes = 262_144
    nonisolated static let staleInterval: TimeInterval = 86_400
    nonisolated private static let requiredCodes = ["USD", "CNY", "EUR", "JPY"]

    @Published private(set) var snapshot: CurrencyRateSnapshot
    @Published private(set) var autoRefreshEnabled: Bool
    @Published private(set) var refreshing: Bool = false
    @Published private(set) var lastError: String? = nil

    private let defaults: UserDefaults
    let cacheURL: URL
    private let fetcher: Fetcher

    init(defaults: UserDefaults = .standard, cacheURL: URL? = nil, fetcher: Fetcher? = nil) {
        self.defaults = defaults
        let resolvedCacheURL = cacheURL ?? Self.defaultCacheURL()
        self.cacheURL = resolvedCacheURL
        self.fetcher = fetcher ?? Self.defaultFetcher
        self.autoRefreshEnabled = defaults.object(forKey: Self.autoRefreshDefaultsKey) as? Bool ?? true
        self.snapshot = Self.loadCachedSnapshot(from: resolvedCacheURL) ?? .fallback
    }

    func setAutoRefreshEnabled(_ enabled: Bool) {
        autoRefreshEnabled = enabled
        defaults.set(enabled, forKey: Self.autoRefreshDefaultsKey)
        if enabled && isStale {
            Task { await refreshIfStale() }
        }
    }

    private var isStale: Bool {
        snapshot.isFallback || Date().timeIntervalSince(snapshot.fetchedAt) >= Self.staleInterval
    }

    func refreshIfStale() async {
        guard autoRefreshEnabled else { return }
        if !snapshot.isFallback && Date().timeIntervalSince(snapshot.fetchedAt) < Self.staleInterval {
            return
        }
        await refreshNow()
    }

    func refreshNow() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }

        do {
            let data = try await fetcher(Self.endpointURL)
            guard data.count <= Self.maxResponseBytes else {
                throw CurrencyRateError.responseTooLarge
            }
            let parsed = try Self.parseOpenERResponse(data, fetchedAt: Date())
            try Self.writeCachedSnapshot(parsed, to: cacheURL)
            snapshot = parsed
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func injectForTesting(_ snapshot: CurrencyRateSnapshot) {
        self.snapshot = snapshot
        self.lastError = nil
    }

    nonisolated static func defaultCacheURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Lumen", isDirectory: true)
            .appendingPathComponent("currency-rates.json", isDirectory: false)
    }

    nonisolated private static let defaultFetcher: Fetcher = { url in
        let session = URLSession(configuration: .default)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CurrencyRateError.badHTTPStatus(http.statusCode)
        }
        guard data.count <= maxResponseBytes else {
            throw CurrencyRateError.responseTooLarge
        }
        return data
    }

    private struct OpenERPayload: Decodable {
        let base_code: String?
        let base: String?
        let time_last_update_utc: String?
        let date: String?
        let rates: [String: Double]?
    }

    nonisolated static func parseOpenERResponse(_ data: Data, fetchedAt: Date = Date()) throws -> CurrencyRateSnapshot {
        guard data.count <= maxResponseBytes,
              let payload = try? JSONDecoder().decode(OpenERPayload.self, from: data),
              let rawRates = payload.rates else {
            throw CurrencyRateError.invalidPayload
        }
        var normalizedRates: [String: Double] = [:]
        normalizedRates.reserveCapacity(rawRates.count)
        for (key, value) in rawRates {
            guard value.isFinite, value > 0 else { continue }
            normalizedRates[key.uppercased()] = value
        }
        for code in requiredCodes {
            guard let rate = normalizedRates[code], rate.isFinite, rate > 0 else {
                throw CurrencyRateError.missingRequiredRates
            }
        }
        let baseCode = (payload.base_code ?? payload.base ?? "USD").uppercased()
        let updatedDate = parseUpdatedDate(
            payload.time_last_update_utc ?? payload.date,
            fallbackDate: fetchedAt
        )
        return CurrencyRateSnapshot(
            base: baseCode,
            rates: normalizedRates,
            updatedDate: updatedDate,
            fetchedAt: fetchedAt,
            isFallback: false
        )
    }

    nonisolated private static func parseUpdatedDate(_ raw: String?, fallbackDate: Date) -> String {
        let isoFormatter = DateFormatter()
        isoFormatter.locale = Locale(identifier: "en_US_POSIX")
        isoFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        isoFormatter.dateFormat = "yyyy-MM-dd"

        if let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            if raw.count >= 10,
               raw.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil {
                return String(raw.prefix(10))
            }
            let rfcFormats = [
                "EEE, dd MMM yyyy HH:mm:ss Z",
                "EEE, d MMM yyyy HH:mm:ss Z",
                "dd MMM yyyy HH:mm:ss Z",
                "yyyy-MM-dd'T'HH:mm:ssZ",
            ]
            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.timeZone = TimeZone(secondsFromGMT: 0)
            for format in rfcFormats {
                parser.dateFormat = format
                if let date = parser.date(from: raw) {
                    return isoFormatter.string(from: date)
                }
            }
        }
        return isoFormatter.string(from: fallbackDate)
    }

    nonisolated private static func hasValidRequiredRates(_ rates: [String: Double]) -> Bool {
        requiredCodes.allSatisfy { code in
            guard let value = rates[code] else { return false }
            return value.isFinite && value > 0
        }
    }

    nonisolated private static func loadCachedSnapshot(from url: URL) -> CurrencyRateSnapshot? {
        guard let data = try? Data(contentsOf: url),
              data.count <= maxResponseBytes,
              let decoded = try? JSONDecoder().decode(CurrencyRateSnapshot.self, from: data),
              hasValidRequiredRates(decoded.rates) else {
            return nil
        }
        return decoded
    }

    nonisolated private static func writeCachedSnapshot(_ snapshot: CurrencyRateSnapshot, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
    }
}
