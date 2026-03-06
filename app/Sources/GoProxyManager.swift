import Foundation
import Combine

/// Manages the Go-based hyper-ai-proxy subprocess.
/// Replaces the old Swift ThinkingProxy with a faster Go HTTP reverse proxy.
class GoProxyManager: ObservableObject {
    let proxyPort: UInt16 = 8317
    @Published private(set) var isRunning = false

    private var process: Process?
    private let processQueue = DispatchQueue(label: "io.hyperai.proxy.go-proxy", qos: .userInitiated)

    // Config synced from ServerManager
    var externalAccessEnabled = false
    var apiKey: String = ""
    var vercelEnabled = false
    var vercelApiKey: String = ""
    var ollamaEnabled = false
    var ollamaURL: String = "http://localhost:11434"

    // MCP server subprocess
    private var mcpProcess: Process?

    private enum Timing {
        static let healthCheckInterval: TimeInterval = 0.1
        static let healthCheckTimeout: Int = 50 // 5 seconds at 100ms intervals
        static let gracefulTerminationTimeout: TimeInterval = 3.0
        static let terminationPollInterval: TimeInterval = 0.05
    }

    /// Starts the Go proxy binary from the app bundle Resources.
    func start() {
        guard !isRunning else {
            NSLog("[GoProxy] Already running")
            return
        }

        guard let binaryPath = locateBinary() else {
            NSLog("[GoProxy] hyper-ai-proxy binary not found in bundle")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = buildArguments()

        // Capture stdout/stderr
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                NSLog("[GoProxy] %@", text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                NSLog("[GoProxy] ERR: %@", text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        proc.terminationHandler = { [weak self] process in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self?.isRunning = false
                NSLog("[GoProxy] Process exited with code %d", process.terminationStatus)
            }
        }

        do {
            try proc.run()
            self.process = proc
            NSLog("[GoProxy] Launched PID %d with args: %@", proc.processIdentifier, proc.arguments?.joined(separator: " ") ?? "")
        } catch {
            NSLog("[GoProxy] Failed to launch: %@", error.localizedDescription)
            return
        }

        // Poll for readiness
        pollHealth(attempt: 0)
    }

    /// Stops the Go proxy gracefully (SIGTERM → wait → SIGKILL).
    func stop() {
        guard let proc = process, proc.isRunning else {
            DispatchQueue.main.async { self.isRunning = false }
            process = nil
            return
        }

        let pid = proc.processIdentifier
        NSLog("[GoProxy] Stopping PID %d", pid)

        processQueue.async { [weak self] in
            proc.terminate()

            let deadline = Date().addingTimeInterval(Timing.gracefulTerminationTimeout)
            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: Timing.terminationPollInterval)
            }

            if proc.isRunning {
                NSLog("[GoProxy] Force killing PID %d", pid)
                kill(pid, SIGKILL)
            }

            proc.waitUntilExit()

            DispatchQueue.main.async {
                self?.process = nil
                self?.isRunning = false
                NSLog("[GoProxy] Stopped")
            }
        }
    }

    /// Rebuilds the command-line arguments from current config state.
    private func buildArguments() -> [String] {
        var args: [String] = [
            "-port", String(proxyPort),
            "-target-port", "8318",
            "-target-host", "127.0.0.1",
        ]

        if externalAccessEnabled {
            args.append("-external-access")
            args.append(contentsOf: ["-bind", "0.0.0.0"])
        } else {
            args.append(contentsOf: ["-bind", "127.0.0.1"])
        }

        if !apiKey.isEmpty {
            args.append(contentsOf: ["-api-key", apiKey])
        }

        if vercelEnabled && !vercelApiKey.isEmpty {
            args.append("-vercel-enabled")
            args.append(contentsOf: ["-vercel-api-key", vercelApiKey])
        }

        if ollamaEnabled {
            args.append("-ollama-enabled")
            args.append(contentsOf: ["-ollama-url", ollamaURL])
        }

        let tokenSpecsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cli-proxy-api")
            .appendingPathComponent("token-specs.json")
            .path
        args.append(contentsOf: ["-token-specs-file", tokenSpecsPath])

        return args
    }

    /// Polls the /internal/health endpoint to detect when the proxy is ready.
    private func pollHealth(attempt: Int) {
        guard let proc = process, proc.isRunning else {
            NSLog("[GoProxy] Process died before becoming ready")
            DispatchQueue.main.async { self.isRunning = false }
            return
        }

        if attempt >= Timing.healthCheckTimeout {
            NSLog("[GoProxy] Health check timed out after %d attempts", attempt)
            stop()
            return
        }

        let url = URL(string: "http://127.0.0.1:\(proxyPort)/internal/health")!
        var request = URLRequest(url: url, timeoutInterval: 1)
        request.httpMethod = "GET"

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                DispatchQueue.main.async {
                    self.isRunning = true
                    NSLog("[GoProxy] Ready on port %d", self.proxyPort)
                }
                return
            }

            // Not ready yet, schedule next poll
            DispatchQueue.global().asyncAfter(deadline: .now() + Timing.healthCheckInterval) {
                self.pollHealth(attempt: attempt + 1)
            }
        }.resume()
    }

    /// Locates the hyper-ai-proxy binary in the app bundle.
    private func locateBinary() -> String? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }
        let path = (resourcePath as NSString).appendingPathComponent("hyper-ai-proxy")
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Locates the hyper-mcp binary in the app bundle.
    private func locateMCPBinary() -> String? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }
        let path = (resourcePath as NSString).appendingPathComponent("hyper-mcp")
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Writes the .mcp.json configuration for Claude Code integration.
    func writeMCPConfig() {
        guard let mcpBinary = locateMCPBinary() else {
            NSLog("[GoProxy] hyper-mcp binary not found in bundle, skipping MCP config")
            return
        }

        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let configPath = homeDir.appendingPathComponent(".claude.json")

        // Check if hyper-proxy already configured — don't overwrite user edits
        if let data = try? Data(contentsOf: configPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let servers = json["mcpServers"] as? [String: Any],
           servers["hyper-proxy"] != nil {
            NSLog("[GoProxy] MCP config already has hyper-proxy entry in ~/.claude.json, skipping write")
            return
        }

        let proxyURL = "http://127.0.0.1:\(proxyPort)"

        do {
            // Read existing ~/.claude.json and merge hyper-proxy into mcpServers
            if let existingData = try? Data(contentsOf: configPath),
               var existingJson = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
                var servers = existingJson["mcpServers"] as? [String: Any] ?? [:]
                servers["hyper-proxy"] = [
                    "type": "stdio",
                    "command": mcpBinary,
                    "args": ["-proxy-url", proxyURL, "-ollama-url", ollamaURL],
                    "env": [String: String]()
                ] as [String: Any]
                existingJson["mcpServers"] = servers
                let data = try JSONSerialization.data(withJSONObject: existingJson, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                try data.write(to: configPath, options: .atomic)
            }

            NSLog("[GoProxy] Wrote MCP config to %@", configPath.path)
        } catch {
            NSLog("[GoProxy] Failed to write MCP config: %@", error.localizedDescription)
        }
    }

    /// Discovers available Ollama models via the proxy API.
    func discoverOllamaModels(completion: @escaping ([OllamaModelInfo]) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:\(proxyPort)/internal/ollama/models") else {
            completion([])
            return
        }

        URLSession.shared.dataTask(with: url) { data, response, error in
            guard let data = data,
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else {
                DispatchQueue.main.async { completion([]) }
                return
            }

            let results = models.compactMap { entry -> OllamaModelInfo? in
                guard let name = entry["name"] as? String,
                      let alias = entry["alias"] as? String else { return nil }
                let size = entry["size_bytes"] as? Int64 ?? 0
                return OllamaModelInfo(name: name, alias: alias, sizeBytes: size)
            }

            DispatchQueue.main.async { completion(results) }
        }.resume()
    }
}

struct OllamaModelInfo {
    let name: String
    let alias: String
    let sizeBytes: Int64

    var sizeDisplay: String {
        let mb = Double(sizeBytes) / (1024 * 1024)
        let gb = mb / 1024
        if gb >= 1 {
            return String(format: "%.1f GB", gb)
        }
        return String(format: "%.0f MB", mb)
    }
}
