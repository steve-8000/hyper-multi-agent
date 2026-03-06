import SwiftUI
import ServiceManagement

private struct ProviderInfo: Identifiable {
    let id: String
    let key: String
    let type: ServiceType
    let icon: String
    let helpText: String?
}

private enum UsagePeriodOption: String, CaseIterable {
    case day
    case week
    case month

    var title: String {
        switch self {
        case .day: return "Day"
        case .week: return "Week"
        case .month: return "Month"
        }
    }

    var days: Int {
        switch self {
        case .day: return 1
        case .week: return 7
        case .month: return 30
        }
    }
}

private struct ProviderUsageWidgetData: Identifiable {
    let id: String
    let providerKey: String
    let providerName: String
    let requestCount: Int
    let totalTokens: Int
    let usedPercent: Int
    let weeklyPercent: Int?
    let models: [String]
    let realWindows: [ProviderUsageWindow]
    let plan: String?
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
        )
    }
}

private struct SectionHeader: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

private struct UsageBarView: View {
    let usedPercent: Int

    private var clamped: Int { min(100, max(0, usedPercent)) }

    private var fillColor: Color {
        if clamped >= 90 { return .red }
        if clamped >= 70 { return .orange }
        return .green
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width * CGFloat(clamped) / 100.0)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.35))
                Capsule()
                    .fill(fillColor)
                    .frame(width: width)
            }
        }
        .frame(height: 8)
    }
}

private struct WeeklyUsageBarView: View {
    let usedPercent: Int

    private var clamped: Int { min(100, max(0, usedPercent)) }

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width * CGFloat(clamped) / 100.0)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.35))
                Capsule()
                    .fill(Color.green)
                    .frame(width: width)
            }
        }
        .frame(height: 6)
    }
}

private struct AccountRowView: View {
    let account: AuthAccount
    let onRemove: () -> Void

    private let removeColor = Color(red: 0xeb / 255, green: 0x0f / 255, blue: 0x0f / 255)

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(account.isExpired ? Color.orange : Color.green)
                .frame(width: 6, height: 6)
            Text(account.displayName)
                .font(.caption)
                .foregroundColor(account.isExpired ? .orange : .secondary)
            if account.isExpired {
                Text("expired")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
            Spacer()
            Button(action: onRemove) {
                Label("Remove", systemImage: "minus.circle.fill")
                    .font(.caption)
                    .foregroundColor(removeColor)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.65))
        )
    }
}

private struct VercelGatewayControls: View {
    @ObservedObject var serverManager: ServerManager
    @State private var showingSaved = false

    var body: some View {
        SettingsCard {
            Toggle(isOn: $serverManager.vercelGatewayEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use Vercel AI Gateway")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text("Route Claude requests through Vercel AI Gateway")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)

            if serverManager.vercelGatewayEnabled {
                HStack(spacing: 8) {
                    SecureField("Vercel API key", text: $serverManager.vercelApiKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    if showingSaved {
                        Text("Saved")
                            .font(.caption)
                            .foregroundColor(.green)
                    } else {
                        Button("Save") {
                            showingSaved = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                showingSaved = false
                            }
                        }
                        .controlSize(.small)
                        .disabled(serverManager.vercelApiKey.isEmpty)
                    }
                }
            }
        }
    }
}

private struct ProviderCard<ExtraContent: View>: View {
    let serviceType: ServiceType
    let iconName: String
    let isEnabled: Bool
    let accounts: [AuthAccount]
    let isAuthenticating: Bool
    let title: String
    let helpText: String?
    let onToggleEnabled: (Bool) -> Void
    let onConnect: () -> Void
    let onDisconnect: (AuthAccount) -> Void
    @ViewBuilder let extraContent: () -> ExtraContent

    @State private var isExpanded = false
    @State private var accountToRemove: AuthAccount?
    @State private var showingRemoveConfirmation = false

    private var activeCount: Int { accounts.filter { !$0.isExpired }.count }
    private var expiredCount: Int { accounts.filter { $0.isExpired }.count }

    private var statusText: String {
        if activeCount > 0 { return "\(activeCount) active" }
        if expiredCount > 0 { return "\(expiredCount) expired" }
        return "No account"
    }

    private var statusColor: Color {
        if activeCount > 0 { return .green }
        if expiredCount > 0 { return .orange }
        return .secondary
    }

    var body: some View {
        SettingsCard {
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(get: { isEnabled }, set: onToggleEnabled))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()

                if let nsImage = IconCatalog.shared.image(named: iconName, resizedTo: NSSize(width: 18, height: 18), template: false) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .renderingMode(.original)
                        .frame(width: 18, height: 18)
                        .opacity(isEnabled ? 1 : 0.45)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(isEnabled ? .primary : .secondary)
                    if let helpText, !helpText.isEmpty {
                        Text(helpText)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 8)

                Text(statusText)
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(statusColor.opacity(0.14))
                    )
                    .foregroundColor(statusColor)

                if isAuthenticating {
                    ProgressView()
                        .controlSize(.small)
                } else if isEnabled {
                    Button("Add Account", action: onConnect)
                        .controlSize(.small)
                }

                if isEnabled {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if isEnabled && isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    if accounts.isEmpty {
                        Text("No connected accounts")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(accounts) { account in
                            AccountRowView(account: account) {
                                accountToRemove = account
                                showingRemoveConfirmation = true
                            }
                        }
                    }
                    extraContent()
                }
                .padding(.top, 4)
            }
        }
        .onAppear {
            if accounts.contains(where: { $0.isExpired }) {
                isExpanded = true
            }
        }
        .onChange(of: accounts) { _, newAccounts in
            if newAccounts.contains(where: { $0.isExpired }) {
                isExpanded = true
            }
        }
        .alert("Remove Account", isPresented: $showingRemoveConfirmation) {
            Button("Cancel", role: .cancel) {
                accountToRemove = nil
            }
            Button("Remove", role: .destructive) {
                if let account = accountToRemove {
                    onDisconnect(account)
                }
                accountToRemove = nil
            }
        } message: {
            if let account = accountToRemove {
                Text("Are you sure you want to remove \(account.displayName) from \(serviceType.displayName)?")
            }
        }
    }
}

private struct LocalModelRow: View {
    let model: LocalModel
    @ObservedObject var serverManager: ServerManager
    @State private var isExpanded = false

    var body: some View {
        SettingsCard {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { model.isEnabled },
                    set: { serverManager.toggleLocalModel(model, enabled: $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()

                if let nsImage = IconCatalog.shared.image(named: "icon-ollama.png", resizedTo: NSSize(width: 16, height: 16), template: false) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .renderingMode(.original)
                        .frame(width: 16, height: 16)
                        .opacity(model.isEnabled ? 1 : 0.45)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(model.name)
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(.semibold)
                    Text(model.endpoint)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("Endpoint")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .frame(width: 56, alignment: .leading)
                        Text(model.endpoint)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }

                    HStack(spacing: 6) {
                        Text("API Key")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .frame(width: 56, alignment: .leading)
                        Text(model.apiKey == "ollama" ? "default" : "••••••••")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Spacer()
                        Button(role: .destructive) {
                            serverManager.removeLocalModel(model)
                        } label: {
                            Label("Remove", systemImage: "trash")
                                .font(.caption2)
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.top, 4)
            }
        }
    }
}

struct AddLocalModelSheet: View {
    @ObservedObject var serverManager: ServerManager
    @Binding var isPresented: Bool

    @State private var modelName = ""
    @State private var endpoint = "http://localhost:11434"
    @State private var apiKey = "ollama"
    @State private var isTesting = false
    @State private var testResult: String? = nil
    @State private var testSuccess = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Local Model")
                    .font(.headline)
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Endpoint URL")
                        .font(.caption)
                        .fontWeight(.medium)
                    TextField("http://localhost:11434", text: $endpoint)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Text("The base URL of your local model server (Ollama, LM Studio, vLLM, etc.)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Model Name")
                        .font(.caption)
                        .fontWeight(.medium)
                    TextField("llama3.2, deepseek-coder, etc.", text: $modelName)
                        .textFieldStyle(.roundedBorder)
                    Text("The exact model name as registered on your server")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("API Key")
                        .font(.caption)
                        .fontWeight(.medium)
                    HStack {
                        SecureField("ollama", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        Button("Default") {
                            apiKey = "ollama"
                        }
                        .controlSize(.small)
                    }
                    Text("Use \"ollama\" for Ollama, or your API key for other OpenAI-compatible servers")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                if let result = testResult {
                    HStack(spacing: 6) {
                        Image(systemName: testSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(testSuccess ? .green : .red)
                        Text(result)
                            .font(.caption)
                            .foregroundColor(testSuccess ? .green : .red)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(testSuccess ? Color.green.opacity(0.1) : Color.red.opacity(0.1))
                    )
                }
            }
            .padding()

            Divider()

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    isTesting = true
                    testResult = nil
                    serverManager.testLocalModelConnection(endpoint: endpoint, model: modelName, apiKey: apiKey) { success, message in
                        isTesting = false
                        testSuccess = success
                        testResult = message
                    }
                } label: {
                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.trailing, 4)
                    }
                    Text("Test Connection")
                }
                .disabled(endpoint.isEmpty || isTesting)

                Button("Add Model") {
                    let model = LocalModel(name: modelName, endpoint: endpoint, apiKey: apiKey)
                    serverManager.addLocalModel(model)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(modelName.isEmpty || endpoint.isEmpty || !testSuccess)
            }
            .padding()
        }
        .frame(width: 440)
    }
}

struct SettingsView: View {
    @ObservedObject var serverManager: ServerManager
    @ObservedObject var statsClient: StatsClient
    @StateObject private var authManager = AuthManager()
    @State private var launchAtLogin = false
    @State private var authenticatingService: ServiceType? = nil
    @State private var showingAuthResult = false
    @State private var authResultMessage = ""
    @State private var authResultSuccess = false
    @State private var fileMonitor: DispatchSourceFileSystemObject?
    @State private var pendingRefresh: DispatchWorkItem?
    @State private var showingAddLocalModel = false
    @AppStorage("usageWidgetPeriod") private var usageWidgetPeriodRaw = UsagePeriodOption.day.rawValue
    @State private var providerUsageSnapshots: [String: ProviderUsageSnapshot] = [:]
    @State private var loadingProviderUsage = false
    @StateObject private var modelRegistry = ModelRegistry.shared
    @State private var showingModelSyncResult = false
    @State private var modelSyncResultMessage = ""
    @State private var modelSyncResultSuccess = false


    private enum Timing {
        static let serverRestartDelay: TimeInterval = 0.3
        static let refreshDebounce: TimeInterval = 0.5
    }

    private struct UnifiedUsageStat {
        let requestCount: Int
        let totalTokens: Int
    }


    init(serverManager: ServerManager, statsClient: StatsClient) {
        self.serverManager = serverManager
        _statsClient = ObservedObject(wrappedValue: statsClient)
    }

    private var providers: [ProviderInfo] {
        [
            ProviderInfo(
                id: "claude",
                key: "claude",
                type: .claude,
                icon: "icon-claude.png",
                helpText: nil
            ),
            ProviderInfo(
                id: "codex",
                key: "codex",
                type: .codex,
                icon: "icon-codex.png",
                helpText: nil
            ),
            ProviderInfo(
                id: "gemini",
                key: "gemini",
                type: .gemini,
                icon: "icon-gemini.png",
                helpText: "If you have multiple projects, your default Google AI Studio project is used."
            ),
            ProviderInfo(
                id: "antigravity",
                key: "antigravity",
                type: .antigravity,
                icon: "icon-antigravity.png",
                helpText: "One login can expose multiple AI services, including Gemini and Claude."
            )
        ]
    }

    private var statusEndpoint: String {
        "http://127.0.0.1:\(serverManager.port)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusCard
                providersSection
                localModelsSection
                claudeIntegrationSection
                externalAccessSection
                usageSection
                appSettingsSection
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("hyper AI")
        .frame(minWidth: 520, idealWidth: 680, maxWidth: 860, minHeight: 600, idealHeight: 840, maxHeight: 1200)
        .onAppear {
            authManager.checkAuthStatus()
            checkLaunchAtLogin()
            startMonitoringAuthDirectory()
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                await refreshProviderUsage()
            }
        }
        .onDisappear {
            stopMonitoringAuthDirectory()
        }
        .onReceive(NotificationCenter.default.publisher(for: .authDirectoryChanged)) { _ in
            authManager.checkAuthStatus()
            Task {
                await refreshProviderUsage()
            }
        }
        .alert("Authentication Result", isPresented: $showingAuthResult) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(authResultMessage)
        }
        .sheet(isPresented: $showingAddLocalModel) {
            AddLocalModelSheet(serverManager: serverManager, isPresented: $showingAddLocalModel)
        }
        .alert(modelSyncResultSuccess ? "Models Synced" : "Sync Failed", isPresented: $showingModelSyncResult) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(modelSyncResultMessage)
        }
    }

    private var statusCard: some View {
        SettingsCard {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.accentColor.opacity(0.12),
                                Color.accentColor.opacity(0.03)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("hyper AI")
                                .font(.system(size: 18, weight: .semibold))
                            Text("Local proxy control center")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(serverManager.isRunning ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            Text(serverManager.isRunning ? "Running" : "Stopped")
                                .font(.caption)
                                .foregroundColor(serverManager.isRunning ? .green : .red)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill((serverManager.isRunning ? Color.green : Color.red).opacity(0.13))
                        )
                    }

                    HStack(spacing: 8) {
                        Label("Server URL", systemImage: "network")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 88, alignment: .leading)
                        Text(statusEndpoint)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(statusEndpoint, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }

                    HStack(spacing: 8) {
                        Button(serverManager.isRunning ? "Stop Server" : "Start Server") {
                            if serverManager.isRunning {
                                serverManager.stop()
                            } else {
                                serverManager.start { _ in }
                            }
                        }
                        .controlSize(.small)

                        Button("Open Auth Folder") {
                            openAuthFolder()
                        }
                        .controlSize(.small)

                        Button {
                            Task {
                                let result = await modelRegistry.sync()
                                modelSyncResultSuccess = result.success
                                modelSyncResultMessage = result.message
                                showingModelSyncResult = true
                                if result.success {
                                    // Hot reload config if server is running
                                    _ = serverManager.getConfigPath()
                                }
                            }
                        } label: {
                            if modelRegistry.isSyncing {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text("Sync Models")
                        }
                        .controlSize(.small)
                        .disabled(modelRegistry.isSyncing)

                        Spacer()
                    }
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var providersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Providers", subtitle: "Connect your model providers and manage account health")

            ForEach(providers) { provider in
                ProviderCard(
                    serviceType: provider.type,
                    iconName: provider.icon,
                    isEnabled: serverManager.isProviderEnabled(provider.key),
                    accounts: authManager.accounts(for: provider.type),
                    isAuthenticating: authenticatingService == provider.type,
                    title: provider.type == .claude && serverManager.vercelGatewayEnabled && !serverManager.vercelApiKey.isEmpty
                        ? "Claude (via Vercel)"
                        : provider.type.displayName,
                    helpText: provider.helpText,
                    onToggleEnabled: { enabled in
                        serverManager.setProviderEnabled(provider.key, enabled: enabled)
                    },
                    onConnect: {
                        connectService(provider.type)
                    },
                    onDisconnect: { account in
                        disconnectAccount(account)
                    }
                ) {
                    if provider.type == .claude {
                        VercelGatewayControls(serverManager: serverManager)
                    }
                }
            }
        }
    }

    private var localModelsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Local Models", subtitle: "Use Ollama or OpenAI-compatible local inference servers")

            SettingsCard {
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(
                        get: { serverManager.isProviderEnabled("ollama") },
                        set: { serverManager.setProviderEnabled("ollama", enabled: $0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()

                    if let nsImage = IconCatalog.shared.image(named: "icon-ollama.png", resizedTo: NSSize(width: 18, height: 18), template: false) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .renderingMode(.original)
                            .frame(width: 18, height: 18)
                    }

                    Text("Local Models")
                        .font(.system(size: 13, weight: .semibold))

                    Spacer()

                    if serverManager.isProviderEnabled("ollama") {
                        Button {
                            discoverOllamaModels()
                        } label: {
                            Label("Discover", systemImage: "antenna.radiowaves.left.and.right")
                        }
                        .controlSize(.small)

                        Button {
                            showingAddLocalModel = true
                        } label: {
                            Label("Add", systemImage: "plus")
                        }
                        .controlSize(.small)
                    }
                }

                if serverManager.isProviderEnabled("ollama") {
                    if serverManager.localModels.isEmpty {
                        Text("No local models configured")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 2)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(serverManager.localModels) { model in
                                LocalModelRow(model: model, serverManager: serverManager)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
            }
        }
    }

    // MARK: - Claude Code Integration

    private var claudeIntegrationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Claude Code Integration", subtitle: "Connect hyper proxy as MCP server for Claude Code")

            SettingsCard {
                HStack(spacing: 10) {
                    Toggle("", isOn: $serverManager.mcpEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()

                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 16))
                        .foregroundColor(.purple)

                    Text("MCP Server")
                        .font(.system(size: 13, weight: .semibold))

                    Spacer()

                    if serverManager.mcpEnabled {
                        Label("Active", systemImage: "circle.fill")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                }

                if serverManager.mcpEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Tools available to Claude Code:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        VStack(alignment: .leading, spacing: 3) {
                            mcpToolRow(name: "ask_model", desc: "Query any model through the proxy")
                            mcpToolRow(name: "list_models", desc: "List remote + local models")
                            mcpToolRow(name: "get_usage", desc: "View usage statistics")
                            mcpToolRow(name: "run_consensus", desc: "Multi-model comparison")
                            mcpToolRow(name: "ollama_status", desc: "Check Ollama status")
                        }
                    }
                    .padding(.top, 4)

                    Divider()

                    HStack {
                        Text("Ollama Direct Routing")
                            .font(.caption)

                        Spacer()

                        Toggle("", isOn: $serverManager.ollamaDirectRouting)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                    }

                    Text("Route local-* models directly to Ollama (faster, bypasses backend)")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Divider()

                    HStack(spacing: 8) {
                        Label("Ollama URL", systemImage: "server.rack")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 100, alignment: .leading)

                        TextField("http://localhost:11434", text: $serverManager.ollamaEndpoint)
                            .font(.system(.caption, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func mcpToolRow(name: String, desc: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "wrench.fill")
                .font(.system(size: 8))
                .foregroundColor(.purple.opacity(0.6))

            Text(name)
                .font(.system(.caption2, design: .monospaced))
                .fontWeight(.medium)

            Text(desc)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var externalAccessSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "External Access", subtitle: "Expose the proxy on your network with API key authentication")

            SettingsCard {
                HStack {
                    Toggle("Enable external access", isOn: $serverManager.externalAccessEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                    Spacer()
                    if serverManager.externalAccessEnabled && serverManager.isRunning {
                        Label("Active", systemImage: "circle.fill")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                }

                if serverManager.externalAccessEnabled {
                    let localIP = ServerManager.getLocalIPAddress() ?? "0.0.0.0"
                    let endpointURL = "http://\(localIP):\(serverManager.port)"

                    SettingsCard {
                        HStack(spacing: 8) {
                            Label("Endpoint", systemImage: "link")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(width: 90, alignment: .leading)
                            Text(endpointURL)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(endpointURL, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                        }

                        Divider()

                        HStack(spacing: 8) {
                            Label("API Key", systemImage: "key.fill")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(width: 90, alignment: .leading)

                            if serverManager.externalApiKey.isEmpty {
                                Text("Not generated")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            } else {
                                Text(serverManager.externalApiKey)
                                    .font(.system(.caption2, design: .monospaced))
                                    .lineLimit(1)
                                    .textSelection(.enabled)
                            }

                            Spacer()

                            Button("Generate") {
                                serverManager.externalApiKey = serverManager.generateApiKey()
                            }
                            .controlSize(.mini)

                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(serverManager.externalApiKey, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                            .disabled(serverManager.externalApiKey.isEmpty)
                        }
                    }

                    Text("Use Authorization: Bearer <key> or x-api-key header to authenticate.")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    SettingsCard {
                        HStack {
                            Text("Connected Services")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button {
                                authManager.checkAuthStatus()
                            } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                        }

                        ForEach(providers) { provider in
                            serviceHealthRow(provider: provider)
                        }

                        if serverManager.isProviderEnabled("ollama") {
                            localModelsHealthRow
                        }
                    }

                    Label("Restart server to apply endpoint or API key changes.", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func serviceHealthRow(provider: ProviderInfo) -> some View {
        let isEnabled = serverManager.isProviderEnabled(provider.key)
        let accounts = authManager.accounts(for: provider.type)
        let activeCount = accounts.filter { !$0.isExpired }.count
        let expiredCount = accounts.filter { $0.isExpired }.count

        HStack(spacing: 8) {
            if let nsImage = IconCatalog.shared.image(named: provider.icon, resizedTo: NSSize(width: 14, height: 14), template: false) {
                Image(nsImage: nsImage)
                    .resizable()
                    .renderingMode(.original)
                    .frame(width: 14, height: 14)
                    .opacity(isEnabled ? 1.0 : 0.35)
            }

            Text(provider.type.displayName)
                .font(.caption)
                .foregroundColor(isEnabled ? .primary : .secondary)

            Spacer()

            if !isEnabled {
                Text("disabled")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else if activeCount > 0 {
                Label("\(activeCount) active", systemImage: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundColor(.green)
            } else if expiredCount > 0 {
                Label("expired", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundColor(.orange)
            } else {
                Label("no account", systemImage: "xmark.circle")
                    .font(.caption2)
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
            }
        }
    }

    private var localModelsHealthRow: some View {
        let enabledModels = serverManager.localModels.filter { $0.isEnabled }

        return HStack(spacing: 8) {
            if let nsImage = IconCatalog.shared.image(named: "icon-ollama.png", resizedTo: NSSize(width: 14, height: 14), template: false) {
                Image(nsImage: nsImage)
                    .resizable()
                    .renderingMode(.original)
                    .frame(width: 14, height: 14)
            }
            Text("Local Models")
                .font(.caption)
            Spacer()
            if enabledModels.isEmpty {
                Label("none configured", systemImage: "minus.circle")
                    .font(.caption2)
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
            } else {
                Text(enabledModels.map(\.name).joined(separator: ", "))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.green)
                    .lineLimit(1)
            }
        }
    }

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Usage", subtitle: "Provider usage, plans, and window-level consumption")

            let usageRows = providerUsageRows()

            SettingsCard {
                HStack {
                    if loadingProviderUsage {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button {
                        Task { await refreshProviderUsage() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Picker("Window", selection: $usageWidgetPeriodRaw) {
                        ForEach(UsagePeriodOption.allCases, id: \.rawValue) { period in
                            Text(period.title).tag(period.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }

                if usageRows.isEmpty {
                    Text("No usage data yet")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    VStack(spacing: 8) {
                        ForEach(usageRows) { row in
                            usageRowCard(row)
                        }
                    }
                }
            }
        }
    }

    private func usageRowCard(_ row: ProviderUsageWidgetData) -> some View {
        SettingsCard {
            HStack(alignment: .top, spacing: 10) {
                if let nsImage = IconCatalog.shared.image(named: usageIconName(for: row.providerKey), resizedTo: NSSize(width: 18, height: 18), template: false) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .renderingMode(.original)
                        .frame(width: 18, height: 18)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(providerTitle(row))
                            .font(.system(.caption, weight: .semibold))
                        Spacer(minLength: 8)
                        Text("\(max(0, 100 - row.usedPercent))% left")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    }

                    UsageBarView(usedPercent: row.usedPercent)

                    if let weeklyPct = row.weeklyPercent {
                        HStack(spacing: 6) {
                            Text("Week")
                                .font(.system(.caption2, weight: .medium))
                                .foregroundColor(.secondary)
                                .frame(width: 32, alignment: .leading)
                            WeeklyUsageBarView(usedPercent: weeklyPct)
                        }
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(row.requestCount) requests")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer(minLength: 8)
                        Text(formatTokenCount(row.totalTokens) + " tokens")
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.secondary)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(providerDetail(row))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                        Spacer(minLength: 8)
                        Text(row.models.prefix(3).joined(separator: ", "))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private func usageIconName(for providerKey: String) -> String {
        switch providerKey {
        case "claude": return "icon-claude.png"
        case "codex": return "icon-codex.png"
        case "gemini": return "icon-gemini.png"
        case "antigravity": return "icon-antigravity.png"
        case "local": return "icon-ollama.png"
        default: return "icon-codex.png"
        }
    }

    private var appSettingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Settings", subtitle: nil)
            SettingsCard {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        toggleLaunchAtLogin(newValue)
                    }

                HStack {
                    Text("Auth files")
                    Spacer()
                    Button("Open Folder") {
                        openAuthFolder()
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func currentUsagePeriod() -> UsagePeriodOption {
        UsagePeriodOption(rawValue: usageWidgetPeriodRaw) ?? .day
    }

    @MainActor
    private func refreshProviderUsage() async {
        loadingProviderUsage = true
        let snapshots = await ProviderUsageService.loadUsage(accountsByType: [
            .claude: authManager.accounts(for: .claude),
            .codex: authManager.accounts(for: .codex),
        ])
        providerUsageSnapshots = snapshots
        loadingProviderUsage = false
    }

    private func preferredWindow(in windows: [ProviderUsageWindow], period: UsagePeriodOption) -> ProviderUsageWindow? {
        guard !windows.isEmpty else { return nil }
        let preferredLabels: [String]
        switch period {
        case .day:
            preferredLabels = ["5h", "Day", "24h"]
        case .week:
            preferredLabels = ["Week", "7d", "168h"]
        case .month:
            preferredLabels = ["Week", "7d", "Day", "5h"]
        }

        for label in preferredLabels {
            if let found = windows.first(where: { $0.label.caseInsensitiveCompare(label) == .orderedSame }) {
                return found
            }
        }

        return windows.first
    }

    private func effectiveUsedPercent(provider: String, estimatedTokens: Int, period: UsagePeriodOption, realWindow: ProviderUsageWindow?) -> Int {
        if let realWindow {
            return max(0, min(100, realWindow.usedPercent))
        }
        let budget = max(1, usageBudget(for: provider, period: period))
        return min(100, Int(round(Double(estimatedTokens) * 100.0 / Double(budget))))
    }

    private func providerTitle(_ row: ProviderUsageWidgetData) -> String {
        var title = row.providerName
        if let plan = row.plan, !plan.isEmpty {
            title += " (\(plan))"
        }
        title += " (\(formatTokenCount(row.totalTokens)))"
        return title
    }

    private func providerDetail(_ row: ProviderUsageWidgetData) -> String {
        if !row.realWindows.isEmpty {
            let ordered = row.realWindows.sorted { a, b in
                windowOrder(a.label) < windowOrder(b.label)
            }
            let parts = ordered.map { window in
                var text = "\(window.label) \(max(0, 100 - window.usedPercent))% left"
                if let resetAt = window.resetAt {
                    text += " | \(timeRemaining(to: resetAt))"
                }
                return text
            }
            return parts.joined(separator: "  ")
        }
        return "\(currentUsagePeriod().title) | \(max(0, 100 - row.usedPercent))% left | \(timeRemaining(to: resetDate(for: currentUsagePeriod())))"
    }

    private func windowOrder(_ label: String) -> Int {
        let lower = label.lowercased()
        if lower == "5h" { return 0 }
        if lower == "day" || lower == "24h" { return 1 }
        if lower == "week" || lower == "7d" || lower == "168h" { return 2 }
        return 10
    }

    private func providerUsageRows() -> [ProviderUsageWidgetData] {
        let period = currentUsagePeriod()
        let stats = unifiedStatsForLastDays(period.days)
        var rows: [ProviderUsageWidgetData] = []

        // Dynamic usage rows from ModelRegistry
        let oauthProviders: [(key: String, serviceType: ServiceType)] = [
            ("claude", .claude),
            ("codex", .codex),
        ]
        for provider in oauthProviders {
            guard serverManager.isProviderEnabled(provider.key) && hasActiveAccount(for: provider.serviceType) else { continue }
            let usageEntries = modelRegistry.usageModels(for: provider.key)
            for entry in usageEntries {
                let modelStats = aggregateUsage(stats) { candidate in entry.matches(candidate) }
                let windows = providerUsageWindows(provider: provider.key, model: entry.id)
                let realWindow = preferredWindow(in: windows, period: period)
                let usedPercent = effectiveUsedPercent(provider: provider.key, estimatedTokens: modelStats.tokens, period: period, realWindow: realWindow)
                let weeklyWindow = windows.first(where: { $0.label.caseInsensitiveCompare("Week") == .orderedSame })
                rows.append(
                    ProviderUsageWidgetData(
                        id: entry.id,
                        providerKey: provider.key,
                        providerName: entry.title,
                        requestCount: modelStats.requests,
                        totalTokens: modelStats.tokens,
                        usedPercent: usedPercent,
                        weeklyPercent: weeklyWindow?.usedPercent,
                        models: [entry.id],
                        realWindows: windows,
                        plan: providerUsageSnapshots[provider.key]?.plan)
                )
            }
        }

        if serverManager.isProviderEnabled("ollama") {
            let enabledLocalModels = serverManager.localModels.filter { $0.isEnabled }
            let localBudget = max(1, usageBudget(for: "local", period: period))
            let perModelBudget = max(1, localBudget / max(1, enabledLocalModels.count))
            for localModel in enabledLocalModels {
                let aliases = localModelAliases(localModel.name)
                let localStats = aggregateUsage(stats) { model in
                    let lower = model.lowercased()
                    return aliases.contains(lower)
                }
                let usedPercent = min(100, Int(round(Double(localStats.tokens) * 100.0 / Double(perModelBudget))))
                rows.append(
                    ProviderUsageWidgetData(
                        id: "local-\(localModel.id.uuidString)",
                        providerKey: "local",
                        providerName: "Local LLM · \(localModel.name)",
                        requestCount: localStats.requests,
                        totalTokens: localStats.tokens,
                        usedPercent: usedPercent,
                        weeklyPercent: nil,
                        models: [localModel.name],
                        realWindows: [],
                        plan: nil)
                )
            }
        }

        return rows
    }

    private func providerUsageWindows(provider: String, model: String) -> [ProviderUsageWindow] {
        guard let snapshot = providerUsageSnapshots[provider] else { return [] }
        if let modelSnapshot = snapshot.modelUsages.first(where: { usage in
            usage.modelName.caseInsensitiveCompare(model) == .orderedSame
        }) {
            return modelSnapshot.windows
        }
        return snapshot.windows
    }

    private func hasActiveAccount(for serviceType: ServiceType) -> Bool {
        authManager.accounts(for: serviceType).contains { !$0.isExpired }
    }

    private func unifiedStatsForLastDays(_ days: Int) -> [String: UnifiedUsageStat] {
        let source = statsClient.statsForLastDays(days)
        return source.mapValues { value in
            UnifiedUsageStat(requestCount: value.requestCount, totalTokens: value.totalTokens)
        }
    }

    private func aggregateUsage(_ stats: [String: UnifiedUsageStat], where include: (String) -> Bool) -> (requests: Int, tokens: Int) {
        var requests = 0
        var tokens = 0
        for (model, modelStats) in stats where include(model) {
            requests += modelStats.requestCount
            tokens += modelStats.totalTokens
        }
        return (requests, tokens)
    }

    private func localModelAliases(_ modelName: String) -> Set<String> {
        let normalized = modelName.lowercased()
        var aliases: Set<String> = [normalized]
        if normalized.hasPrefix("local-") {
            aliases.insert(String(normalized.dropFirst(6)))
        } else {
            aliases.insert("local-\(normalized)")
        }
        aliases.insert("ollama-\(normalized)")
        return aliases
    }

    private func usageBudget(for provider: String, period: UsagePeriodOption) -> Int {
        let perDay: Int
        switch provider {
        case "local": perDay = 2_000_000
        case "claude", "codex", "gemini": perDay = 800_000
        case "antigravity": perDay = 500_000
        default: perDay = 500_000
        }
        return perDay * period.days
    }

    private func formatTokenCount(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000.0) }
        if value >= 1000 { return String(format: "%.1fK", Double(value) / 1000.0) }
        return "\(value)"
    }

    private func resetDate(for period: UsagePeriodOption) -> Date {
        let now = Date()
        let calendar = Calendar.current
        switch period {
        case .day:
            return calendar.startOfDay(for: now.addingTimeInterval(86400))
        case .week:
            let weekday = calendar.component(.weekday, from: now)
            let delta = (9 - weekday) % 7
            let daysToAdd = delta == 0 ? 7 : delta
            let target = calendar.date(byAdding: .day, value: daysToAdd, to: now) ?? now
            return calendar.startOfDay(for: target)
        case .month:
            var c = calendar.dateComponents([.year, .month], from: now)
            c.month = (c.month ?? 1) + 1
            c.day = 1
            return calendar.date(from: c) ?? now
        }
    }

    private func timeRemaining(to date: Date) -> String {
        let interval = max(0, Int(date.timeIntervalSinceNow))
        let days = interval / 86_400
        let hours = (interval % 86_400) / 3600
        if days > 0 { return "\(days)d \(hours)h" }
        let minutes = (interval % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private func openAuthFolder() {
        let authDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cli-proxy-api")
        NSWorkspace.shared.open(authDir)
    }

    private func toggleLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("[SettingsView] Failed to toggle launch at login: %@", error.localizedDescription)
            }
        }
    }

    private func checkLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func connectService(_ serviceType: ServiceType) {
        authenticatingService = serviceType
        NSLog("[SettingsView] Starting %@ authentication", serviceType.displayName)

        let command: AuthCommand
        switch serviceType {
        case .claude: command = .claudeLogin
        case .codex: command = .codexLogin
        case .gemini: command = .geminiLogin
        case .antigravity: command = .antigravityLogin
        default:
            authenticatingService = nil
            return
        }

        serverManager.runAuthCommand(command) { success, output in
            NSLog("[SettingsView] Auth completed - success: %d, output: %@", success, output)
            DispatchQueue.main.async {
                self.authenticatingService = nil

                if success {
                    self.authResultSuccess = true
                    self.authResultMessage = self.successMessage(for: serviceType)
                    self.showingAuthResult = true
                } else {
                    self.authResultSuccess = false
                    self.authResultMessage = "Authentication failed. Please check if the browser opened and try again.\n\nDetails: \(output.isEmpty ? "No output from authentication process" : output)"
                    self.showingAuthResult = true
                }
            }
        }
    }

    private func successMessage(for serviceType: ServiceType) -> String {
        switch serviceType {
        case .claude:
            return "Browser opened for Claude authentication.\n\nComplete login in your browser.\n\nCredentials will be detected automatically."
        case .codex:
            return "Browser opened for Codex authentication.\n\nComplete login in your browser.\n\nCredentials will be detected automatically."
        case .gemini:
            return "Browser opened for Gemini authentication.\n\nComplete login in your browser.\n\nIf you use multiple projects, your default project is used."
        case .antigravity:
            return "Browser opened for Antigravity authentication.\n\nComplete login in your browser."
        default:
            return "Authentication completed successfully."
        }
    }

    private func disconnectAccount(_ account: AuthAccount) {
        let wasRunning = serverManager.isRunning

        let cleanup = {
            if self.authManager.deleteAccount(account) {
                self.authResultSuccess = true
                self.authResultMessage = "Removed \(account.displayName) from \(account.type.displayName)"
            } else {
                self.authResultSuccess = false
                self.authResultMessage = "Failed to remove account"
            }
            self.showingAuthResult = true

            if wasRunning {
                DispatchQueue.main.asyncAfter(deadline: .now() + Timing.serverRestartDelay) {
                    self.serverManager.start { _ in }
                }
            }
        }

        if wasRunning {
            serverManager.stop { cleanup() }
        } else {
            cleanup()
        }
    }

    private func startMonitoringAuthDirectory() {
        let authDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cli-proxy-api")
        try? FileManager.default.createDirectory(at: authDir, withIntermediateDirectories: true)

        let fileDescriptor = open(authDir.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename],
            queue: DispatchQueue.main
        )

        source.setEventHandler { [self] in
            pendingRefresh?.cancel()
            let workItem = DispatchWorkItem {
                NSLog("[FileMonitor] Auth directory changed - refreshing status")
                authManager.checkAuthStatus()
                Task {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    await refreshProviderUsage()
                }
            }
            pendingRefresh = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + Timing.refreshDebounce, execute: workItem)
        }

        source.setCancelHandler {
            close(fileDescriptor)
        }

        source.resume()
        fileMonitor = source
    }

    private func stopMonitoringAuthDirectory() {
        pendingRefresh?.cancel()
        fileMonitor?.cancel()
        fileMonitor = nil
    }

    private func discoverOllamaModels() {
        let ollamaURL = serverManager.ollamaEndpoint.isEmpty ? "http://localhost:11434" : serverManager.ollamaEndpoint
        let tagsURL = ollamaURL.hasSuffix("/") ? "\(ollamaURL)api/tags" : "\(ollamaURL)/api/tags"

        guard let url = URL(string: tagsURL) else { return }

        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "GET"

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data,
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else {
                return
            }

            let existingNames = Set(serverManager.localModels.map { $0.name.lowercased() })

            DispatchQueue.main.async {
                for modelEntry in models {
                    guard let name = modelEntry["name"] as? String else { continue }
                    if existingNames.contains(name.lowercased()) { continue }
                    let endpoint = serverManager.ollamaEndpoint.isEmpty ? "http://localhost:11434" : serverManager.ollamaEndpoint
                    let newModel = LocalModel(name: name, endpoint: endpoint, apiKey: "ollama", isEnabled: true)
                    serverManager.addLocalModel(newModel)
                }
            }
        }.resume()
    }
}
