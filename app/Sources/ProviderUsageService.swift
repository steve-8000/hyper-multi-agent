import Foundation

struct ProviderUsageWindow {
    let label: String
    let usedPercent: Int
    let resetAt: Date?
}

struct ProviderModelUsageSnapshot {
    let modelName: String
    let windows: [ProviderUsageWindow]
}

struct ProviderUsageSnapshot {
    let providerKey: String
    let plan: String?
    let windows: [ProviderUsageWindow]
    let modelUsages: [ProviderModelUsageSnapshot]
}

enum ProviderUsageService {
    static func loadUsage(accountsByType: [ServiceType: [AuthAccount]]) async -> [String: ProviderUsageSnapshot] {
        async let claude = loadClaudeUsage(accounts: accountsByType[.claude] ?? [])
        async let codex = loadCodexUsage(accounts: accountsByType[.codex] ?? [])

        var result: [String: ProviderUsageSnapshot] = [:]
        if let claudeSnapshot = await claude {
            result[claudeSnapshot.providerKey] = claudeSnapshot
        }
        if let codexSnapshot = await codex {
            result[codexSnapshot.providerKey] = codexSnapshot
        }
        return result
    }

    private static func loadClaudeUsage(accounts: [AuthAccount]) async -> ProviderUsageSnapshot? {
        for account in accounts where !account.isExpired {
            guard let json = readJsonFile(at: account.filePath),
                  let token = json["access_token"] as? String,
                  !token.isEmpty else {
                continue
            }

            var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 10)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("openclaw", forHTTPHeaderField: "User-Agent")

            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            var windows: [ProviderUsageWindow] = []

            if let five = payload["five_hour"] as? [String: Any],
               let utilization = doubleValue(five["utilization"]) {
                windows.append(
                    ProviderUsageWindow(
                        label: "5h",
                        usedPercent: clampPercent(utilization),
                        resetAt: parseDate(five["resets_at"])))
            }

            if let seven = payload["seven_day"] as? [String: Any],
               let utilization = doubleValue(seven["utilization"]) {
                windows.append(
                    ProviderUsageWindow(
                        label: "Week",
                        usedPercent: clampPercent(utilization),
                        resetAt: parseDate(seven["resets_at"])))
            }

            if let sonnet = payload["seven_day_sonnet"] as? [String: Any],
               let utilization = doubleValue(sonnet["utilization"]) {
                windows.append(
                    ProviderUsageWindow(
                        label: "Sonnet",
                        usedPercent: clampPercent(utilization),
                        resetAt: nil))
            }

            if let opus = payload["seven_day_opus"] as? [String: Any],
               let utilization = doubleValue(opus["utilization"]) {
                windows.append(
                    ProviderUsageWindow(
                        label: "Opus",
                        usedPercent: clampPercent(utilization),
                        resetAt: nil))
            }

            if !windows.isEmpty {
                let sonnetWeek = utilizationWindow(
                    payload: payload,
                    key: "seven_day_sonnet",
                    fallbackKey: "seven_day",
                    fallbackLabel: "Week")
                let opusWeek = utilizationWindow(
                    payload: payload,
                    key: "seven_day_opus",
                    fallbackKey: "seven_day",
                    fallbackLabel: "Week")
                let fiveHour = utilizationWindow(payload: payload, key: "five_hour", fallbackKey: nil, fallbackLabel: "5h")

                let sonnetWindows = [fiveHour, sonnetWeek].compactMap { $0 }
                let opusWindows = [fiveHour, opusWeek].compactMap { $0 }

                var modelUsages: [ProviderModelUsageSnapshot] = []
                if !sonnetWindows.isEmpty {
                    modelUsages.append(ProviderModelUsageSnapshot(modelName: "claude-sonnet-4-6", windows: sonnetWindows))
                }
                if !opusWindows.isEmpty {
                    modelUsages.append(ProviderModelUsageSnapshot(modelName: "claude-opus-4-6", windows: opusWindows))
                }

                return ProviderUsageSnapshot(providerKey: "claude", plan: nil, windows: windows, modelUsages: modelUsages)
            }
        }

        return nil
    }

    private static func loadCodexUsage(accounts: [AuthAccount]) async -> ProviderUsageSnapshot? {
        for account in accounts where !account.isExpired {
            guard let json = readJsonFile(at: account.filePath),
                  let token = json["access_token"] as? String,
                  !token.isEmpty else {
                continue
            }

            let accountId = extractChatGPTAccountId(from: json)

            var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!, timeoutInterval: 10)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")
            if let accountId, !accountId.isEmpty {
                request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
            }

            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            var windows: [ProviderUsageWindow] = []

            if let rateLimit = payload["rate_limit"] as? [String: Any],
               let primary = rateLimit["primary_window"] as? [String: Any],
               let used = doubleValue(primary["used_percent"]) {
                let reset = unixSecondsDate(primary["reset_at"])
                windows.append(ProviderUsageWindow(label: "5h", usedPercent: clampPercent(used), resetAt: reset))
            }

            if let rateLimit = payload["rate_limit"] as? [String: Any],
               let secondary = rateLimit["secondary_window"] as? [String: Any],
               let used = doubleValue(secondary["used_percent"]) {
                let seconds = intValue(secondary["limit_window_seconds"]) ?? 86_400
                let label = seconds >= 604_800 ? "Week" : (seconds >= 86_400 ? "Day" : "\(max(1, seconds / 3600))h")
                let reset = unixSecondsDate(secondary["reset_at"])
                windows.append(ProviderUsageWindow(label: label, usedPercent: clampPercent(used), resetAt: reset))
            }

            var modelUsages: [ProviderModelUsageSnapshot] = []
            if !windows.isEmpty {
                modelUsages.append(ProviderModelUsageSnapshot(modelName: "gpt-5.3-codex", windows: windows))
            }

            if let additional = payload["additional_rate_limits"] as? [[String: Any]] {
                for entry in additional {
                    guard let limitName = entry["limit_name"] as? String,
                          let rate = entry["rate_limit"] as? [String: Any] else {
                        continue
                    }

                    var modelWindows: [ProviderUsageWindow] = []
                    if let primary = rate["primary_window"] as? [String: Any],
                       let used = doubleValue(primary["used_percent"]) {
                        modelWindows.append(
                            ProviderUsageWindow(
                                label: "5h",
                                usedPercent: clampPercent(used),
                                resetAt: unixSecondsDate(primary["reset_at"])))
                    }
                    if let secondary = rate["secondary_window"] as? [String: Any],
                       let used = doubleValue(secondary["used_percent"]) {
                        let seconds = intValue(secondary["limit_window_seconds"]) ?? 86_400
                        let label = seconds >= 604_800 ? "Week" : (seconds >= 86_400 ? "Day" : "\(max(1, seconds / 3600))h")
                        modelWindows.append(
                            ProviderUsageWindow(
                                label: label,
                                usedPercent: clampPercent(used),
                                resetAt: unixSecondsDate(secondary["reset_at"])))
                    }

                    guard !modelWindows.isEmpty else { continue }
                    modelUsages.append(
                        ProviderModelUsageSnapshot(
                            modelName: codexModelName(fromLimitName: limitName),
                            windows: modelWindows))
                }
            }

            var plan: String?
            if let rawPlan = payload["plan_type"] as? String, !rawPlan.isEmpty {
                plan = rawPlan
            }
            if let credits = payload["credits"] as? [String: Any], let balance = doubleValue(credits["balance"]) {
                let balanceText = String(format: "$%.2f", balance)
                plan = plan.map { "\($0) (\(balanceText))" } ?? balanceText
            }

            if !windows.isEmpty {
                return ProviderUsageSnapshot(providerKey: "codex", plan: plan, windows: windows, modelUsages: modelUsages)
            }
        }

        return nil
    }

    private static func readJsonFile(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private static func extractChatGPTAccountId(from authJson: [String: Any]) -> String? {
        if let idToken = authJson["id_token"] as? String,
           let payload = decodeJWTPayload(idToken),
           let auth = payload["https://api.openai.com/auth"] as? [String: Any],
           let accountId = auth["chatgpt_account_id"] as? String,
           !accountId.isEmpty {
            return accountId
        }
        if let accessToken = authJson["access_token"] as? String,
           let payload = decodeJWTPayload(accessToken),
           let auth = payload["https://api.openai.com/auth"] as? [String: Any],
           let accountId = auth["chatgpt_account_id"] as? String,
           !accountId.isEmpty {
            return accountId
        }
        return nil
    }

    private static func decodeJWTPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = payload.count % 4
        if pad != 0 {
            payload += String(repeating: "=", count: 4 - pad)
        }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private static func clampPercent(_ value: Double) -> Int {
        let safe = value.isFinite ? value : 0
        return max(0, min(100, Int(round(safe))))
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private static func unixSecondsDate(_ value: Any?) -> Date? {
        guard let seconds = doubleValue(value) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func parseDate(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private static func utilizationWindow(payload: [String: Any], key: String, fallbackKey: String?, fallbackLabel: String) -> ProviderUsageWindow? {
        if let target = payload[key] as? [String: Any],
           let utilization = doubleValue(target["utilization"]) {
            return ProviderUsageWindow(label: fallbackLabel, usedPercent: clampPercent(utilization), resetAt: parseDate(target["resets_at"]))
        }
        if let fallbackKey,
           let target = payload[fallbackKey] as? [String: Any],
           let utilization = doubleValue(target["utilization"]) {
            return ProviderUsageWindow(label: fallbackLabel, usedPercent: clampPercent(utilization), resetAt: parseDate(target["resets_at"]))
        }
        return nil
    }

    private static func codexModelName(fromLimitName limitName: String) -> String {
        let lower = limitName.lowercased()
        if lower.contains("spark") {
            return "gpt-5.3-codex-spark"
        }
        if lower.contains("codex") {
            return "gpt-5.3-codex"
        }
        return limitName
    }
}
