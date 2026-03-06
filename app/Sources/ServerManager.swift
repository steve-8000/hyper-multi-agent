import Foundation
import Combine
import AppKit
#if canImport(Darwin)
import Darwin
#endif

private struct RingBuffer<Element> {
    private var storage: [Element?]
    private var head = 0
    private var tail = 0
    private(set) var count = 0
    
    init(capacity: Int) {
        let safeCapacity = max(1, capacity)
        storage = Array(repeating: nil, count: safeCapacity)
    }
    
    mutating func append(_ element: Element) {
        let capacity = storage.count
        storage[tail] = element
        
        if count == capacity {
            head = (head + 1) % capacity
        } else {
            count += 1
        }
        
        tail = (tail + 1) % capacity
    }
    
    func elements() -> [Element] {
        let capacity = storage.count
        guard count > 0 else { return [] }
        
        var result: [Element] = []
        result.reserveCapacity(count)
        
        for index in 0..<count {
            let storageIndex = (head + index) % capacity
            if let value = storage[storageIndex] {
                result.append(value)
            }
        }
        
        return result
    }
}

struct LocalModel: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var endpoint: String
    var apiKey: String
    var isEnabled: Bool

    init(id: UUID = UUID(), name: String, endpoint: String, apiKey: String = "ollama", isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.isEnabled = isEnabled
    }
}

class ServerManager: ObservableObject {
    private var process: Process?
    private let modelRegistry = ModelRegistry.shared
    @Published private(set) var isRunning = false
    private(set) var port = 8317

    /// Provider enabled states - when disabled, models are excluded via oauth-excluded-models
    @Published var enabledProviders: [String: Bool] = [:] {
        didSet {
            UserDefaults.standard.set(enabledProviders, forKey: "enabledProviders")
        }
    }

    /// Vercel AI Gateway configuration for Claude requests
    @Published var vercelGatewayEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(vercelGatewayEnabled, forKey: "vercelGatewayEnabled")
            onVercelConfigChanged?()
        }
    }
    @Published var vercelApiKey: String = "" {
        didSet {
            UserDefaults.standard.set(vercelApiKey, forKey: "vercelApiKey")
            onVercelConfigChanged?()
        }
    }
    @Published var externalAccessEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(externalAccessEnabled, forKey: "externalAccessEnabled")
            onExternalAccessConfigChanged?()
        }
    }
    @Published var externalApiKey: String = "" {
        didSet {
            UserDefaults.standard.set(externalApiKey, forKey: "externalApiKey")
            onExternalAccessConfigChanged?()
        }
    }
    @Published var localModels: [LocalModel] = [] {
        didSet {
            saveLocalModels()
        }
    }
    @Published var ollamaDirectRouting: Bool = true {
        didSet {
            UserDefaults.standard.set(ollamaDirectRouting, forKey: "ollamaDirectRouting")
            onOllamaConfigChanged?()
        }
    }
    @Published var ollamaEndpoint: String = "http://localhost:11434" {
        didSet {
            UserDefaults.standard.set(ollamaEndpoint, forKey: "ollamaEndpoint_v2")
            onOllamaConfigChanged?()
        }
    }
    @Published var mcpEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(mcpEnabled, forKey: "mcpEnabled")
        }
    }
    var onVercelConfigChanged: (() -> Void)?
    var onExternalAccessConfigChanged: (() -> Void)?
    var onOllamaConfigChanged: (() -> Void)?

    /// Helper class to capture output text across closures
    private class OutputCapture {
        var text = ""
    }
    private var logBuffer: RingBuffer<String>
    private let maxLogLines = 1000
    private let processQueue = DispatchQueue(label: "io.hyperai.proxy.server-process", qos: .userInitiated)
    
    private enum Timing {
        static let readinessCheckDelay: TimeInterval = 1.0
        static let gracefulTerminationTimeout: TimeInterval = 2.0
        static let terminationPollInterval: TimeInterval = 0.05
    }
    
    var onLogUpdate: (([String]) -> Void)?

    /// OAuth provider keys used in config.yaml oauth-excluded-models
    static let oauthProviderKeys: [String: String] = [
        "claude": "claude",
        "codex": "codex",
        "gemini": "gemini-cli",
        "antigravity": "antigravity"
    ]

    static let hardExcludedProviders: [String] = ["github-copilot"]

    init() {
        logBuffer = RingBuffer(capacity: maxLogLines)
        if let saved = UserDefaults.standard.dictionary(forKey: "enabledProviders") as? [String: Bool] {
            enabledProviders = saved
        }
        vercelGatewayEnabled = UserDefaults.standard.bool(forKey: "vercelGatewayEnabled")
        vercelApiKey = UserDefaults.standard.string(forKey: "vercelApiKey") ?? ""
        externalAccessEnabled = UserDefaults.standard.bool(forKey: "externalAccessEnabled")
        externalApiKey = UserDefaults.standard.string(forKey: "externalApiKey") ?? ""
        ollamaDirectRouting = UserDefaults.standard.object(forKey: "ollamaDirectRouting") as? Bool ?? true
        ollamaEndpoint = UserDefaults.standard.string(forKey: "ollamaEndpoint_v2") ?? "http://localhost:11434"
        mcpEnabled = UserDefaults.standard.object(forKey: "mcpEnabled") as? Bool ?? true
        loadLocalModels()
        modelRegistry.writeTokenSpecsForGoProxy()
    }

    private func saveLocalModels() {
        if let data = try? JSONEncoder().encode(localModels) {
            UserDefaults.standard.set(data, forKey: "localModels")
        }
    }

    private func loadLocalModels() {
        if let data = UserDefaults.standard.data(forKey: "localModels"),
           let models = try? JSONDecoder().decode([LocalModel].self, from: data) {
            localModels = models
            return
        }

        let oldEndpoint = UserDefaults.standard.string(forKey: "ollamaEndpoint") ?? ""
        let oldModels = UserDefaults.standard.string(forKey: "ollamaModels") ?? ""
        if !oldModels.isEmpty {
            let modelNames = oldModels
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            localModels = modelNames.map {
                LocalModel(name: $0, endpoint: oldEndpoint.isEmpty ? "http://localhost:11434" : oldEndpoint, apiKey: "ollama")
            }

            UserDefaults.standard.removeObject(forKey: "ollamaEndpoint")
            UserDefaults.standard.removeObject(forKey: "ollamaModels")
        }
    }

    /// Check if a provider is enabled (defaults to true if not set)
    func isProviderEnabled(_ providerKey: String) -> Bool {
        return enabledProviders[providerKey] ?? true
    }

    /// Set provider enabled state and regenerate config (hot reload - no restart needed)
    func setProviderEnabled(_ providerKey: String, enabled: Bool) {
        enabledProviders[providerKey] = enabled
        addLog(enabled ? "✓ Enabled provider: \(providerKey)" : "⚠️ Disabled provider: \(providerKey)")

        // Regenerate config - CLIProxyAPI hot reloads config.yaml automatically
        _ = getConfigPath()
        addLog("Config updated (hot reload)")
    }

    func addLocalModel(_ model: LocalModel) {
        localModels.append(model)
        addLog("✓ Added local model: \(model.name) at \(model.endpoint)")
        if isProviderEnabled("ollama") {
            _ = getConfigPath()
            addLog("Config updated (hot reload)")
        }
    }

    func removeLocalModel(_ model: LocalModel) {
        localModels.removeAll { $0.id == model.id }
        addLog("✓ Removed local model: \(model.name)")
        if isProviderEnabled("ollama") {
            _ = getConfigPath()
            addLog("Config updated (hot reload)")
        }
    }

    func toggleLocalModel(_ model: LocalModel, enabled: Bool) {
        if let index = localModels.firstIndex(where: { $0.id == model.id }) {
            localModels[index].isEnabled = enabled
            _ = getConfigPath()
        }
    }

    func testLocalModelConnection(endpoint: String, model: String, apiKey: String, completion: @escaping (Bool, String) -> Void) {
        let _ = model
        let urlString = endpoint.hasSuffix("/") ? "\(endpoint)v1/models" : "\(endpoint)/v1/models"
        guard let url = URL(string: urlString) else {
            completion(false, "Invalid endpoint URL")
            return
        }

        var request = URLRequest(url: url, timeoutInterval: 5)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    let ollamaUrl = endpoint.hasSuffix("/") ? "\(endpoint)api/tags" : "\(endpoint)/api/tags"
                    guard let fallbackUrl = URL(string: ollamaUrl) else {
                        completion(false, "Connection failed: \(error.localizedDescription)")
                        return
                    }
                    URLSession.shared.dataTask(with: fallbackUrl) { _, response2, error2 in
                        DispatchQueue.main.async {
                            if let error2 = error2 {
                                completion(false, "Connection failed: \(error2.localizedDescription)")
                            } else if let httpResponse = response2 as? HTTPURLResponse, httpResponse.statusCode == 200 {
                                completion(true, "Connected (Ollama)")
                            } else {
                                completion(false, "Server returned error")
                            }
                        }
                    }.resume()
                    return
                }

                if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode == 200 {
                        completion(true, "Connected successfully")
                    } else if httpResponse.statusCode == 401 {
                        completion(false, "Authentication failed - check API key")
                    } else {
                        completion(false, "Server returned status \(httpResponse.statusCode)")
                    }
                } else {
                    completion(false, "Unexpected response")
                }
            }
        }.resume()
    }

    func generateApiKey() -> String {
        let chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        let key = "clp_" + String((0..<32).map { _ in chars.randomElement()! })
        return key
    }

    static func getLocalIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            guard let sockAddr = interface.ifa_addr else { continue }
            let addrFamily = sockAddr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name == "en1" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(
                        sockAddr,
                        socklen_t(sockAddr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                    address = String(cString: hostname)
                    if name == "en0" { break }
                }
            }
        }
        return address
    }

    static var providerModels: [String: [String]] {
        ModelRegistry.shared.providerModels
    }
    
    deinit {
        // Ensure cleanup on deallocation
        stop()
        killOrphanedProcesses()
    }
    
    func start(completion: @escaping (Bool) -> Void) {
        guard !isRunning else {
            completion(true)
            return
        }

        // Clean up any orphaned processes from previous crashes
        killOrphanedProcesses()

        // Use bundled binary from app bundle
        guard let resourcePath = Bundle.main.resourcePath else {
            addLog("❌ Error: Could not find resource path")
            completion(false)
            return
        }
        
        let bundledPath = (resourcePath as NSString).appendingPathComponent("cli-proxy-api-plus")
        guard FileManager.default.fileExists(atPath: bundledPath) else {
            addLog("❌ Error: cli-proxy-api-plus binary not found at \(bundledPath)")
            completion(false)
            return
        }
        
        let configPath = getConfigPath()
        guard !configPath.isEmpty && FileManager.default.fileExists(atPath: configPath) else {
            addLog("❌ Error: config.yaml not found")
            completion(false)
            return
        }
        
        process = Process()
        process?.executableURL = URL(fileURLWithPath: bundledPath)
        process?.arguments = ["-config", configPath]
        
        // Setup pipes for output
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process?.standardOutput = outputPipe
        process?.standardError = errorPipe
        
        // Handle output
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                self?.addLog(output)
            }
        }
        
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                self?.addLog("⚠️ \(output)")
            }
        }
        
        // Handle termination
        process?.terminationHandler = { [weak self] process in
            // Clear pipe handlers to prevent memory leaks
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.addLog("Server stopped with code: \(process.terminationStatus)")
                NotificationCenter.default.post(name: .serverStatusChanged, object: nil)
            }
        }
        
        do {
            try process?.run()
            DispatchQueue.main.async {
                self.isRunning = true
            }
            addLog("✓ Server started on port \(port)")
            
            // Wait a bit to ensure it started successfully
            DispatchQueue.main.asyncAfter(deadline: .now() + Timing.readinessCheckDelay) { [weak self] in
                guard let self = self else { return }
                if let process = self.process, process.isRunning {
                    NotificationCenter.default.post(name: .serverStatusChanged, object: nil)
                    completion(true)
                } else {
                    self.addLog("⚠️ Server exited before becoming ready")
                    completion(false)
                }
            }
        } catch {
            addLog("❌ Failed to start server: \(error.localizedDescription)")
            completion(false)
        }
    }
    
    func stop(completion: (() -> Void)? = nil) {
        guard let process = process else {
            DispatchQueue.main.async {
                self.isRunning = false
                NotificationCenter.default.post(name: .serverStatusChanged, object: nil)
                completion?()
            }
            return
        }
        
        let pid = process.processIdentifier
        addLog("Stopping server (PID: \(pid))...")
        processQueue.async { [weak self] in
            guard let self = self else { return }
            
            // First try graceful termination (SIGTERM)
            process.terminate()
            
            // Wait up to configured interval for graceful termination
            let deadline = Date().addingTimeInterval(Timing.gracefulTerminationTimeout)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: Timing.terminationPollInterval)
            }
            
            // If still running, force kill (SIGKILL)
            if process.isRunning {
                self.addLog("⚠️ Server didn't stop gracefully, force killing...")
                kill(pid, SIGKILL)
            }
            
            process.waitUntilExit()
            
            DispatchQueue.main.async {
                self.process = nil
                self.isRunning = false
                self.addLog("✓ Server stopped")
                NotificationCenter.default.post(name: .serverStatusChanged, object: nil)
                completion?()
            }
        }
    }
    
    func runAuthCommand(_ command: AuthCommand, completion: @escaping (Bool, String) -> Void) {
        // Use bundled binary from app bundle
        guard let resourcePath = Bundle.main.resourcePath else {
            completion(false, "Could not find resource path")
            return
        }
        
        let bundledPath = (resourcePath as NSString).appendingPathComponent("cli-proxy-api-plus")
        guard FileManager.default.fileExists(atPath: bundledPath) else {
            completion(false, "Binary not found at \(bundledPath)")
            return
        }
        
        let authProcess = Process()
        authProcess.executableURL = URL(fileURLWithPath: bundledPath)
        
        // Get the config path
        let configPath = (resourcePath as NSString).appendingPathComponent("config.yaml")
        
        switch command {
        case .claudeLogin:
            authProcess.arguments = ["--config", configPath, "-claude-login"]
        case .codexLogin:
            authProcess.arguments = ["--config", configPath, "-codex-login"]
        case .geminiLogin:
            authProcess.arguments = ["--config", configPath, "-login"]
        case .antigravityLogin:
            authProcess.arguments = ["--config", configPath, "-antigravity-login"]
        }
        
        // Create pipes for output
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = Pipe()
        authProcess.standardOutput = outputPipe
        authProcess.standardError = errorPipe
        authProcess.standardInput = inputPipe
        
        let capture = OutputCapture()
        
        // For Gemini login, automatically send newline to accept default project
        if case .geminiLogin = command {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 3.0) {
                // Send newline after 3 seconds to accept default project choice
                if authProcess.isRunning {
                    if let data = "\n".data(using: .utf8) {
                        try? inputPipe.fileHandleForWriting.write(contentsOf: data)
                        NSLog("[Auth] Sent newline to accept default project")
                    }
                }
            }
        }

        // For Codex login, avoid blocking on the manual callback prompt after ~15s.
        if case .codexLogin = command {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 12.0) {
                // Send newline before the prompt to keep waiting for browser callback.
                if authProcess.isRunning {
                    if let data = "\n".data(using: .utf8) {
                        try? inputPipe.fileHandleForWriting.write(contentsOf: data)
                        NSLog("[Auth] Sent newline to keep Codex login waiting for callback")
                    }
                }
            }
        }
        
        // Set environment to inherit from parent
        authProcess.environment = ProcessInfo.processInfo.environment
        
        do {
            NSLog("[Auth] Starting process: %@ with args: %@", bundledPath, authProcess.arguments?.joined(separator: " ") ?? "none")
            try authProcess.run()
            addLog("✓ Authentication process started (PID: \(authProcess.processIdentifier)) - browser should open shortly")
            NSLog("[Auth] Process started with PID: %d", authProcess.processIdentifier)
            
            // Set up termination handler to detect when auth completes
            authProcess.terminationHandler = { process in
                let exitCode = process.terminationStatus
                NSLog("[Auth] Process terminated with exit code: %d", exitCode)
                
                if exitCode == 0 {
                    // Authentication completed successfully
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        // Give file system a moment to write the credential file
                        NotificationCenter.default.post(name: .authDirectoryChanged, object: nil)
                    }
                }
            }
            
            // Wait briefly to check if process crashes immediately or to capture output
            let waitTime: TimeInterval = 1.0
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + waitTime) {
                if authProcess.isRunning {
                    NSLog("[Auth] Process running after wait, returning success")

                    completion(true, "🌐 Browser opened for authentication.\n\nPlease complete the login in your browser.\n\nThe app will automatically detect when you're authenticated.")
                } else {
                    // Process died quickly - check for error
                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    
                    var output = String(data: outputData, encoding: .utf8) ?? ""
                    if output.isEmpty { output = capture.text }
                    let error = String(data: errorData, encoding: .utf8) ?? ""
                    
                    NSLog("[Auth] Process died quickly - output: %@", output.isEmpty ? "(empty)" : String(output.prefix(200)))
                    
                    if output.contains("Opening browser") || output.contains("Attempting to open URL") {
                        // Browser opened but process finished (probably success)
                        NSLog("[Auth] Browser opened, process completed")
                        completion(true, "🌐 Browser opened for authentication.\n\nPlease complete the login in your browser.\n\nThe app will automatically detect when you're authenticated.")
                    } else {
                        // Real error
                        NSLog("[Auth] Process failed")
                        let message = error.isEmpty ? (output.isEmpty ? "Authentication process failed unexpectedly" : output) : error
                        completion(false, message)
                    }
                }
            }
        } catch {
            NSLog("[Auth] Failed to start: %@", error.localizedDescription)
            completion(false, "Failed to start auth process: \(error.localizedDescription)")
        }
    }
    
    private func addLog(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            let logLine = "[\(timestamp)] \(message)"
            
            self.logBuffer.append(logLine)
            self.onLogUpdate?(self.logBuffer.elements())
        }
    }
    
    func getConfigPath() -> String {
        guard let resourcePath = Bundle.main.resourcePath else {
            return ""
        }

        let bundledConfigPath = (resourcePath as NSString).appendingPathComponent("config.yaml")
        let authDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cli-proxy-api")

        // Build list of disabled providers
        var disabledProviders: [String] = []
        for (serviceKey, oauthKey) in Self.oauthProviderKeys {
            if !isProviderEnabled(serviceKey) {
                disabledProviders.append(oauthKey)
            }
        }
        disabledProviders.append(contentsOf: Self.hardExcludedProviders)
        disabledProviders = Array(Set(disabledProviders))

        let enabledLocalModels = localModels.filter { $0.isEnabled }
        let groupedModels = Dictionary(grouping: enabledLocalModels) { "\($0.endpoint)|\($0.apiKey)" }

        guard !disabledProviders.isEmpty || (isProviderEnabled("ollama") && !enabledLocalModels.isEmpty) else {
            return bundledConfigPath
        }

        // Generate merged config
        guard let bundledContent = try? String(contentsOfFile: bundledConfigPath, encoding: .utf8) else {
            return bundledConfigPath
        }
        
        var additionalConfig = ""

        // Build oauth-excluded-models section for disabled providers
        if !disabledProviders.isEmpty {
            additionalConfig += """

# Provider exclusions (auto-added by hyper AI)
# Disabled providers have all models excluded
oauth-excluded-models:

"""
            for provider in disabledProviders.sorted() {
                additionalConfig += "  \(provider):\n"
                additionalConfig += "    - \"*\"\n"
            }
        }

        if isProviderEnabled("ollama") && !enabledLocalModels.isEmpty {
            additionalConfig += "\n# Local Model Providers (auto-added by hyper AI)\nopenai-compatibility:\n"
            for (index, (key, models)) in groupedModels.sorted(by: { $0.key < $1.key }).enumerated() {
                let parts = key.components(separatedBy: "|")
                let endpoint = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let apiKey = (parts.count > 1 ? parts[1] : "ollama").trimmingCharacters(in: .whitespacesAndNewlines)
                let endpointUrl = normalizeOpenAICompatibilityEndpoint(endpoint)
                additionalConfig += "  - name: \"local-\(index)\"\n    base-url: \"\(endpointUrl)\"\n    api-key-entries:\n      - api-key: \"\(apiKey)\"\n    models:\n"
                for model in models {
                    let modelName = normalizeLocalModelName(model.name)
                    guard !modelName.isEmpty else { continue }
                    additionalConfig += "      - name: \"\(modelName)\"\n        alias: \"local-\(modelName)\"\n"
                }
            }
        }

        let mergedContent = bundledContent + additionalConfig
        let mergedConfigPath = authDir.appendingPathComponent("merged-config.yaml")
        
        do {
            try FileManager.default.createDirectory(at: authDir, withIntermediateDirectories: true)
            try mergedContent.write(to: mergedConfigPath, atomically: true, encoding: .utf8)
            // Set secure permissions (0600 - owner read/write only) since config contains API keys
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: mergedConfigPath.path)
            return mergedConfigPath.path
        } catch {
            NSLog("[ServerManager] Failed to write merged config: %@", error.localizedDescription)
            return bundledConfigPath
        }
    }

    private func normalizeOpenAICompatibilityEndpoint(_ endpoint: String) -> String {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed), let scheme = components.scheme, !scheme.isEmpty else {
            let base = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
            return base.hasSuffix("/v1") ? base : "\(base)/v1"
        }

        let path = components.path
        if path.isEmpty || path == "/" {
            components.path = "/v1"
        } else if !path.hasSuffix("/v1") {
            components.path = path.hasSuffix("/") ? "\(path)v1" : "\(path)/v1"
        }

        return components.string ?? (trimmed.hasSuffix("/v1") ? trimmed : "\(trimmed)/v1")
    }

    private func normalizeLocalModelName(_ name: String) -> String {
        var normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("local-") {
            normalized = String(normalized.dropFirst("local-".count))
        }
        return normalized
    }
    
    func getLogs() -> [String] {
        return logBuffer.elements()
    }
    
    /// Kill any orphaned cli-proxy-api-plus processes that might be running
    private func killOrphanedProcesses() {
        // First check if any processes exist using pgrep
        let checkTask = Process()
        checkTask.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        checkTask.arguments = ["-f", "cli-proxy-api-plus"]
        
        let outputPipe = Pipe()
        checkTask.standardOutput = outputPipe
        checkTask.standardError = Pipe() // Suppress errors
        
        do {
            try checkTask.run()
            checkTask.waitUntilExit()
            
            // If pgrep found processes (exit code 0), kill them
            if checkTask.terminationStatus == 0 {
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                let pids = output.components(separatedBy: .newlines).filter { !$0.isEmpty }
                
                if !pids.isEmpty {
                    addLog("⚠️ Found orphaned server process(es): \(pids.joined(separator: ", "))")
                    
                    // Now kill them
                    let killTask = Process()
                    killTask.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
                    killTask.arguments = ["-9", "-f", "cli-proxy-api-plus"]
                    
                    try killTask.run()
                    killTask.waitUntilExit()
                    
                    // Wait a moment for cleanup
                    Thread.sleep(forTimeInterval: 0.5)
                    addLog("✓ Cleaned up orphaned processes")
                }
            }
            // Exit code 1 means no processes found - this is fine, no need to log
        } catch {
            // Silently fail - this is not critical
        }
    }
}

enum AuthCommand: Equatable {
    case claudeLogin
    case codexLogin
    case geminiLogin
    case antigravityLogin
}
