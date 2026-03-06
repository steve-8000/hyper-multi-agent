import Foundation
import Combine

/// Represents a model entry used for usage tracking UI
struct UsageModelEntry: Codable, Equatable {
    let id: String
    let title: String
    let prefixMatch: [String]
    let excludePrefix: [String]?

    /// Returns true if the given candidate model name matches this usage model
    func matches(_ candidate: String) -> Bool {
        let lower = candidate.lowercased()
        if let excludes = excludePrefix {
            for prefix in excludes where lower.hasPrefix(prefix.lowercased()) {
                return false
            }
        }
        for prefix in prefixMatch where lower.hasPrefix(prefix.lowercased()) {
            return true
        }
        return false
    }
}

/// Represents a provider's model configuration
struct ProviderModelConfig: Codable, Equatable {
    let providerModels: [String]
    let usageModels: [UsageModelEntry]
}

/// Represents a model's token spec for the Go proxy
struct TokenSpec: Codable, Equatable {
    let contextWindow: Int
    let maxOutputTokens: Int
}

/// Full remote model registry payload
struct ModelRegistryPayload: Codable, Equatable {
    let version: Int
    let providers: [String: ProviderModelConfig]
    let tokenSpecs: [String: TokenSpec]
}

/// Manages model definitions with remote sync, local cache, and bundled fallback.
/// Fetches from GitHub raw URL, caches to UserDefaults, writes tokenSpecs JSON for Go proxy.
class ModelRegistry: ObservableObject {
    static let shared = ModelRegistry()

    private static let remoteURL = URL(string: "https://raw.githubusercontent.com/automazeio/vibeproxy/main/models.json")!
    private static let cacheKey = "modelRegistryCache"
    private static let cacheTimestampKey = "modelRegistryCacheTimestamp"

    @Published private(set) var payload: ModelRegistryPayload
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var lastSyncError: String?

    private init() {
        // Load from cache first, fallback to bundled defaults
        if let cached = Self.loadFromCache() {
            payload = cached
            lastSyncDate = UserDefaults.standard.object(forKey: Self.cacheTimestampKey) as? Date
        } else {
            payload = Self.bundledDefaults()
        }
    }

    // MARK: - Public API

    /// Provider model patterns (replaces ServerManager.providerModels)
    var providerModels: [String: [String]] {
        var result: [String: [String]] = [:]
        for (key, config) in payload.providers {
            result[key] = config.providerModels
        }
        return result
    }

    /// Usage model entries for a given provider
    func usageModels(for provider: String) -> [UsageModelEntry] {
        payload.providers[provider]?.usageModels ?? []
    }

    /// Token specs map
    var tokenSpecs: [String: TokenSpec] {
        payload.tokenSpecs
    }

    /// Sync from remote, updating cache and publishing changes
    @MainActor
    func sync() async -> (success: Bool, message: String) {
        isSyncing = true
        lastSyncError = nil
        defer { isSyncing = false }

        do {
            var request = URLRequest(url: Self.remoteURL, timeoutInterval: 15)
            request.cachePolicy = .reloadIgnoringLocalCacheData

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let msg = "Server returned status \(code)"
                lastSyncError = msg
                return (false, msg)
            }

            let decoded = try JSONDecoder().decode(ModelRegistryPayload.self, from: data)

            // Validate version
            guard decoded.version >= 1 else {
                let msg = "Invalid registry version: \(decoded.version)"
                lastSyncError = msg
                return (false, msg)
            }

            // Update state
            payload = decoded
            lastSyncDate = Date()

            // Persist to cache
            Self.saveToCache(data: data)

            // Write tokenSpecs JSON for Go proxy
            writeTokenSpecsForGoProxy()

            let modelCount = decoded.tokenSpecs.count
            let providerCount = decoded.providers.count
            return (true, "Synced \(modelCount) models from \(providerCount) providers")

        } catch {
            let msg = "Sync failed: \(error.localizedDescription)"
            lastSyncError = msg
            return (false, msg)
        }
    }

    /// Write tokenSpecs as JSON to ~/.cli-proxy-api/token-specs.json for Go proxy to read
    func writeTokenSpecsForGoProxy() {
        let authDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cli-proxy-api")
        let specsPath = authDir.appendingPathComponent("token-specs.json")

        do {
            try FileManager.default.createDirectory(at: authDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload.tokenSpecs)
            try data.write(to: specsPath, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: specsPath.path)
            NSLog("[ModelRegistry] Wrote token-specs.json (%d specs)", payload.tokenSpecs.count)
        } catch {
            NSLog("[ModelRegistry] Failed to write token-specs.json: %@", error.localizedDescription)
        }
    }

    // MARK: - Cache

    private static func saveToCache(data: Data) {
        UserDefaults.standard.set(data, forKey: cacheKey)
        UserDefaults.standard.set(Date(), forKey: cacheTimestampKey)
    }

    private static func loadFromCache() -> ModelRegistryPayload? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(ModelRegistryPayload.self, from: data)
    }

    // MARK: - Bundled Defaults

    private static func bundledDefaults() -> ModelRegistryPayload {
        ModelRegistryPayload(
            version: 1,
            providers: [
                "claude": ProviderModelConfig(
                    providerModels: ["claude-sonnet-4-5-*", "claude-opus-4-*", "claude-haiku-3-5-*", "claude-*-thinking-*"],
                    usageModels: [
                        UsageModelEntry(
                            id: "claude-opus-4-6",
                            title: "Claude · Opus 4.6",
                            prefixMatch: ["claude-opus-4-6", "claude-sonnet-4-6"],
                            excludePrefix: nil)
                    ]),
                "codex": ProviderModelConfig(
                    providerModels: ["o4-mini", "o3", "gpt-4.1", "codex-mini-*"],
                    usageModels: [
                        UsageModelEntry(
                            id: "gpt-5.3-codex",
                            title: "Codex · GPT-5.3-Codex",
                            prefixMatch: ["gpt-5.3-codex"],
                            excludePrefix: ["gpt-5.3-codex-spark"]),
                        UsageModelEntry(
                            id: "gpt-5.3-codex-spark",
                            title: "Codex · GPT-5.3-Codex-Spark",
                            prefixMatch: ["gpt-5.3-codex-spark"],
                            excludePrefix: nil)
                    ]),
                "gemini": ProviderModelConfig(
                    providerModels: ["gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.0-*"],
                    usageModels: []),
                "antigravity": ProviderModelConfig(
                    providerModels: ["claude-*", "gemini-* (via Antigravity)"],
                    usageModels: [])
            ],
            tokenSpecs: [
                "claude-opus-4-6": TokenSpec(contextWindow: 200000, maxOutputTokens: 128000),
                "claude-sonnet-4-6": TokenSpec(contextWindow: 200000, maxOutputTokens: 64000),
                "gpt-5.3-codex": TokenSpec(contextWindow: 400000, maxOutputTokens: 128000),
                "gpt-5.3-codex-spark": TokenSpec(contextWindow: 125000, maxOutputTokens: 8192)
            ]
        )
    }
}
