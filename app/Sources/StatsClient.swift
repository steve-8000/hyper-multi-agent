import Foundation
import Combine

/// Fetches usage statistics from the Go proxy's /internal/stats endpoint.
/// Replaces the in-process UsageTracker with an HTTP-based stats client.
class StatsClient: ObservableObject {
    struct ModelStats: Codable {
        var requestCount: Int = 0
        var promptTokens: Int = 0
        var completionTokens: Int = 0
        var totalTokens: Int = 0

        enum CodingKeys: String, CodingKey {
            case requestCount = "request_count"
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }

        mutating func merge(_ other: ModelStats) {
            requestCount += other.requestCount
            promptTokens += other.promptTokens
            completionTokens += other.completionTokens
            totalTokens += other.totalTokens
        }
    }

    struct StatsResponse: Codable {
        let daily: [String: [String: ModelStats]]
        let totals: [String: ModelStats]
    }

    @Published private(set) var stats: [String: ModelStats] = [:]
    @Published private(set) var dailyStats: [String: [String: ModelStats]] = [:]

    private let proxyPort: UInt16
    private let session: URLSession

    init(proxyPort: UInt16 = 8317) {
        self.proxyPort = proxyPort
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 5
        self.session = URLSession(configuration: config)
    }

    /// Fetches current stats from the Go proxy.
    @MainActor
    func refresh() async {
        guard let url = URL(string: "http://127.0.0.1:\(proxyPort)/internal/stats") else { return }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }

            let decoded = try JSONDecoder().decode(StatsResponse.self, from: data)
            self.stats = decoded.totals
            self.dailyStats = decoded.daily
        } catch {
            NSLog("[StatsClient] Failed to fetch stats: %@", error.localizedDescription)
        }
    }

    /// Returns aggregated stats for the last N days.
    func statsForLastDays(_ days: Int) -> [String: ModelStats] {
        guard days > 0 else { return stats }

        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        guard let cutoff = calendar.date(byAdding: .day, value: -(days - 1), to: todayStart) else {
            return stats
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current

        var merged: [String: ModelStats] = [:]
        for (dayKey, modelMap) in dailyStats {
            guard let dayDate = formatter.date(from: dayKey), dayDate >= cutoff else { continue }
            for (model, value) in modelMap {
                var current = merged[model] ?? ModelStats()
                current.merge(value)
                merged[model] = current
            }
        }

        return merged
    }

    /// Compatibility: no-op. Stats are managed by the Go proxy.
    func resetAll() {
        // Stats reset would need to be implemented in Go proxy if needed
    }
}
