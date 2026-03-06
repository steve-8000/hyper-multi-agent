import Cocoa
import SwiftUI
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var menu: NSMenu!
    weak var settingsWindow: NSWindow?
    var serverManager: ServerManager!
    var goProxy: GoProxyManager!
    var statsClient: StatsClient!
    private let notificationCenter = UNUserNotificationCenter.current()
    private var notificationPermissionGranted = false
    private var usageMenuRows: [MenuUsageRow] = []
    private let modelRegistry = ModelRegistry.shared
    private var providerUsageSnapshots: [String: ProviderUsageSnapshot] = [:]
    private var lastUsageRefresh: Date?
    private var usageRefreshTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupMenuBar()

        // Initialize managers
        serverManager = ServerManager()
        goProxy = GoProxyManager()
        statsClient = StatsClient(proxyPort: goProxy.proxyPort)

        // Sync config from ServerManager to GoProxy
        syncVercelConfig()
        serverManager.onVercelConfigChanged = { [weak self] in
            self?.syncVercelConfig()
        }
        syncExternalAccessConfig()
        serverManager.onExternalAccessConfigChanged = { [weak self] in
            self?.syncExternalAccessConfig()
        }
        syncOllamaConfig()
        serverManager.onOllamaConfigChanged = { [weak self] in
            self?.syncOllamaConfig()
        }

        preloadIcons()
        configureNotifications()

        // Start server automatically
        startServer()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateMenuBarStatus),
            name: .serverStatusChanged,
            object: nil
        )

        refreshUsageMenuIfNeeded(force: true)
    }

    private func preloadIcons() {
        let statusIconSize = NSSize(width: 18, height: 18)
        let serviceIconSize = NSSize(width: 20, height: 20)

        let iconsToPreload = [
            ("icon-active.png", statusIconSize),
            ("icon-inactive.png", statusIconSize),
            ("icon-codex.png", serviceIconSize),
            ("icon-claude.png", serviceIconSize),
            ("icon-gemini.png", serviceIconSize),
            ("icon-ollama.png", serviceIconSize)
        ]

        for (name, size) in iconsToPreload {
            if IconCatalog.shared.image(named: name, resizedTo: size, template: true) == nil {
                NSLog("[IconPreload] Warning: Failed to preload icon '%@'", name)
            }
        }
    }

    private func configureNotifications() {
        notificationCenter.delegate = self
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            if let error = error {
                NSLog("[Notifications] Authorization failed: %@", error.localizedDescription)
            }
            DispatchQueue.main.async {
                self?.notificationPermissionGranted = granted
                if !granted {
                    NSLog("[Notifications] Authorization not granted; notifications will be suppressed")
                }
            }
        }
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About hyper AI", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit hyper AI", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApplication.shared.mainMenu = mainMenu
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            if let icon = IconCatalog.shared.image(named: "icon-inactive.png", resizedTo: NSSize(width: 18, height: 18), template: true) {
                button.image = icon
            } else {
                let fallback = NSImage(systemSymbolName: "network.slash", accessibilityDescription: "hyper AI")
                fallback?.isTemplate = true
                button.image = fallback
                NSLog("[MenuBar] Failed to load inactive icon from bundle; using fallback system icon")
            }
        }

        menu = NSMenu()
        menu.delegate = self

        // Status Header — custom view with background
        let statusHeaderItem = NSMenuItem()
        statusHeaderItem.tag = 99
        statusHeaderItem.view = makeStatusHeaderView(running: false)
        menu.addItem(statusHeaderItem)

        // Usage section inserted dynamically at index 1

        menu.addItem(NSMenuItem.separator())

        // Settings
        let settingsItem = NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        menu.addItem(NSMenuItem(title: "Quit hyper AI", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshUsageMenuIfNeeded(force: false)
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            createSettingsWindow()
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func createSettingsWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "hyper AI"
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false

        let contentView = SettingsView(serverManager: serverManager, statsClient: statsClient)
        window.contentView = NSHostingView(rootView: contentView)

        settingsWindow = window
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow {
            settingsWindow = nil
        }
    }

    @objc func toggleServer() {
        if serverManager.isRunning {
            stopServer()
        } else {
            startServer()
        }
    }

    func startServer() {
        // Sync config before starting
        syncVercelConfig()
        syncExternalAccessConfig()
        syncOllamaConfig()

        // Write MCP config for Claude Code integration
        if serverManager.mcpEnabled {
            goProxy.writeMCPConfig()
        }

        // Start the Go proxy first (port 8317)
        goProxy.start()

        // Poll for Go proxy readiness with timeout
        pollForProxyReadiness(attempts: 0, maxAttempts: 60, intervalMs: 100)
    }

    private func pollForProxyReadiness(attempts: Int, maxAttempts: Int, intervalMs: Int) {
        if goProxy.isRunning {
            // Go proxy ready — start backend
            serverManager.start { [weak self] success in
                DispatchQueue.main.async {
                    if success {
                        self?.updateMenuBarStatus()
                        self?.showNotification(title: "Server Started", body: "hyper AI is now running")
                    } else {
                        self?.goProxy.stop()
                        self?.showNotification(title: "Server Failed", body: "Could not start backend server on port 8318")
                    }
                }
            }
            return
        }

        if attempts >= maxAttempts {
            DispatchQueue.main.async { [weak self] in
                self?.goProxy.stop()
                self?.showNotification(title: "Server Failed", body: "Could not start proxy on port 8317 (timeout)")
            }
            return
        }

        let interval = Double(intervalMs) / 1000.0
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            self?.pollForProxyReadiness(attempts: attempts + 1, maxAttempts: maxAttempts, intervalMs: intervalMs)
        }
    }

    func stopServer() {
        goProxy.stop()
        serverManager.stop()
        updateMenuBarStatus()
    }

    @objc func copyServerURL() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("http://localhost:\(goProxy.proxyPort)", forType: .string)
        showNotification(title: "Copied", body: "Server URL copied to clipboard")
    }

    @objc func updateMenuBarStatus() {
        // Update status header view
        if let statusMenuItem = menu.item(withTag: 99) {
            statusMenuItem.view = makeStatusHeaderView(running: serverManager.isRunning)
        }

        rebuildUsageMenuSection()
        refreshUsageMenuIfNeeded(force: false)

        if let button = statusItem.button {
            let iconName = serverManager.isRunning ? "icon-active.png" : "icon-inactive.png"
            let fallbackSymbol = serverManager.isRunning ? "network" : "network.slash"

            if let icon = IconCatalog.shared.image(named: iconName, resizedTo: NSSize(width: 18, height: 18), template: true) {
                button.image = icon
            } else {
                let fallback = NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: serverManager.isRunning ? "Running" : "Stopped")
                fallback?.isTemplate = true
                button.image = fallback
            }
        }
    }

    func showNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "io.hyperai.proxy.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        notificationCenter.add(request) { error in
            if let error = error {
                NSLog("[Notifications] Failed to deliver notification '%@': %@", title, error.localizedDescription)
            }
        }
    }

    @objc func quit() {
        if serverManager.isRunning {
            goProxy.stop()
            serverManager.stop()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: .serverStatusChanged, object: nil)
        if serverManager.isRunning {
            goProxy.stop()
            serverManager.stop()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if serverManager.isRunning {
            goProxy.stop()
            serverManager.stop()
        }
        return .terminateNow
    }

    // MARK: - Config Sync

    private func syncVercelConfig() {
        goProxy.vercelEnabled = serverManager.vercelGatewayEnabled
        goProxy.vercelApiKey = serverManager.vercelApiKey
    }

    private func syncExternalAccessConfig() {
        goProxy.externalAccessEnabled = serverManager.externalAccessEnabled
        goProxy.apiKey = serverManager.externalApiKey
    }

    private func syncOllamaConfig() {
        goProxy.ollamaEnabled = serverManager.ollamaDirectRouting && serverManager.isProviderEnabled("ollama")
        goProxy.ollamaURL = serverManager.ollamaEndpoint
    }

    // MARK: - Usage Menu

    private struct MenuUsageRow {
        let id: String
        let title: String
        let usedPercent: Int
        let weeklyPercent: Int?
        let detail: String
    }

    private func refreshUsageMenuIfNeeded(force: Bool) {
        if !force, let last = lastUsageRefresh, Date().timeIntervalSince(last) < 45 {
            return
        }
        usageRefreshTask?.cancel()
        usageRefreshTask = Task { [weak self] in
            guard let self else { return }

            // Refresh stats from Go proxy
            await self.statsClient.refresh()

            let accountsByType = self.loadAccountsByType()
            let snapshots = await ProviderUsageService.loadUsage(accountsByType: accountsByType)
            if Task.isCancelled { return }
            let rows = self.buildMenuUsageRows(accountsByType: accountsByType, snapshots: snapshots)
            await MainActor.run {
                self.providerUsageSnapshots = snapshots
                self.usageMenuRows = rows
                self.lastUsageRefresh = Date()
                self.rebuildUsageMenuSection()
            }
        }
    }

    private func rebuildUsageMenuSection() {
        let usageTags = Set(2000..<2100)
        for item in menu.items.reversed() where usageTags.contains(item.tag) {
            menu.removeItem(item)
        }

        guard !usageMenuRows.isEmpty else { return }
        var insertionIndex = 1  // After status header (index 0)

        let leadingSeparator = NSMenuItem.separator()
        leadingSeparator.tag = 2000
        menu.insertItem(leadingSeparator, at: insertionIndex)
        insertionIndex += 1

        let header = NSMenuItem(title: "Usage", action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.tag = 2001
        menu.insertItem(header, at: insertionIndex)
        insertionIndex += 1

        for (offset, row) in usageMenuRows.enumerated() {
            let item = NSMenuItem()
            item.tag = 2002 + offset
            item.isEnabled = false
            item.view = usageMenuView(for: row)
            menu.insertItem(item, at: insertionIndex)
            insertionIndex += 1
        }

        let trailingSeparator = NSMenuItem.separator()
        trailingSeparator.tag = 2099
        menu.insertItem(trailingSeparator, at: insertionIndex)
    }

    private func usageMenuView(for row: MenuUsageRow) -> NSView {
        let titleLabel = NSTextField(labelWithString: row.title)
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor

        let detailLabel = NSTextField(labelWithString: row.detail)
        detailLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor

        // 5h usage bar
        let progress = NSProgressIndicator()
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 100
        progress.doubleValue = Double(min(100, max(0, row.usedPercent)))
        progress.controlSize = .small
        progress.style = .bar

        var stackViews: [NSView] = [titleLabel, progress]

        // Weekly usage bar (green)
        if let weeklyPct = row.weeklyPercent {
            let weeklyContainer = NSView()
            weeklyContainer.translatesAutoresizingMaskIntoConstraints = false

            let weeklyLabel = NSTextField(labelWithString: "Week")
            weeklyLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
            weeklyLabel.textColor = .secondaryLabelColor
            weeklyLabel.translatesAutoresizingMaskIntoConstraints = false

            let weeklyTrack = NSView()
            weeklyTrack.wantsLayer = true
            weeklyTrack.layer = CALayer()
            weeklyTrack.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.35).cgColor
            weeklyTrack.layer?.cornerRadius = 3
            weeklyTrack.translatesAutoresizingMaskIntoConstraints = false

            let weeklyFill = NSView()
            weeklyFill.wantsLayer = true
            weeklyFill.layer = CALayer()
            weeklyFill.layer?.backgroundColor = NSColor(red: 74/255, green: 222/255, blue: 128/255, alpha: 1).cgColor
            weeklyFill.layer?.cornerRadius = 3
            weeklyFill.translatesAutoresizingMaskIntoConstraints = false

            weeklyTrack.addSubview(weeklyFill)
            weeklyContainer.addSubview(weeklyLabel)
            weeklyContainer.addSubview(weeklyTrack)

            let clampedWeekly = CGFloat(min(100, max(0, weeklyPct)))
            NSLayoutConstraint.activate([
                weeklyContainer.heightAnchor.constraint(equalToConstant: 14),

                weeklyLabel.leadingAnchor.constraint(equalTo: weeklyContainer.leadingAnchor),
                weeklyLabel.centerYAnchor.constraint(equalTo: weeklyContainer.centerYAnchor),
                weeklyLabel.widthAnchor.constraint(equalToConstant: 32),

                weeklyTrack.leadingAnchor.constraint(equalTo: weeklyLabel.trailingAnchor, constant: 4),
                weeklyTrack.trailingAnchor.constraint(equalTo: weeklyContainer.trailingAnchor),
                weeklyTrack.centerYAnchor.constraint(equalTo: weeklyContainer.centerYAnchor),
                weeklyTrack.heightAnchor.constraint(equalToConstant: 6),

                weeklyFill.leadingAnchor.constraint(equalTo: weeklyTrack.leadingAnchor),
                weeklyFill.topAnchor.constraint(equalTo: weeklyTrack.topAnchor),
                weeklyFill.bottomAnchor.constraint(equalTo: weeklyTrack.bottomAnchor),
                weeklyFill.widthAnchor.constraint(equalTo: weeklyTrack.widthAnchor, multiplier: clampedWeekly / 100.0),
            ])

            stackViews.append(weeklyContainer)
        }

        stackViews.append(detailLabel)

        let stack = NSStackView(views: stackViews)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let hasWeekly = row.weeklyPercent != nil
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: hasWeekly ? 66 : 48))
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            progress.widthAnchor.constraint(equalToConstant: 260),
        ])

        return container
    }

    private func makeStatusHeaderView(running: Bool) -> NSView {
        let width: CGFloat = 300
        let height: CGFloat = 36

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true

        // Background with rounded corners and brand gradient
        let bgLayer = CAGradientLayer()
        bgLayer.frame = NSRect(x: 8, y: 2, width: width - 16, height: height - 4)
        bgLayer.cornerRadius = 8
        if running {
            bgLayer.colors = [
                NSColor(red: 124/255, green: 58/255, blue: 237/255, alpha: 0.85).cgColor,
                NSColor(red: 59/255, green: 130/255, blue: 246/255, alpha: 0.85).cgColor,
            ]
        } else {
            bgLayer.colors = [
                NSColor(white: 0.3, alpha: 0.6).cgColor,
                NSColor(white: 0.2, alpha: 0.6).cgColor,
            ]
        }
        bgLayer.startPoint = CGPoint(x: 0, y: 0.5)
        bgLayer.endPoint = CGPoint(x: 1, y: 0.5)
        container.layer = CALayer()
        container.layer?.addSublayer(bgLayer)

        // Status dot
        let dot = NSView(frame: NSRect(x: 20, y: (height - 8) / 2, width: 8, height: 8))
        dot.wantsLayer = true
        dot.layer = CALayer()
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = running
            ? NSColor(red: 74/255, green: 222/255, blue: 128/255, alpha: 1).cgColor
            : NSColor(red: 239/255, green: 68/255, blue: 68/255, alpha: 1).cgColor
        container.addSubview(dot)

        // Label: "hyper AI  Running" or "hyper AI  Stopped"
        let label = NSTextField(labelWithString: running ? "hyper AI  Running" : "hyper AI  Stopped")
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.frame = NSRect(x: 36, y: (height - 18) / 2, width: width - 60, height: 18)
        container.addSubview(label)

        return container
    }

    private func buildMenuUsageRows(accountsByType: [ServiceType: [AuthAccount]], snapshots: [String: ProviderUsageSnapshot]) -> [MenuUsageRow] {
        let stats = statsClient.statsForLastDays(1)
        var rows: [MenuUsageRow] = []

        let oauthProviders: [(key: String, type: ServiceType)] = [
            ("claude", .claude),
            ("codex", .codex),
        ]
        for provider in oauthProviders {
            guard serverManager.isProviderEnabled(provider.key), hasActiveAccount(accountsByType, provider.type) else { continue }
            let usageEntries = modelRegistry.usageModels(for: provider.key)
            for entry in usageEntries {
                let estimatedTokens = aggregateTokens(stats) { candidate in entry.matches(candidate) }
                let windows = providerWindows(snapshots[provider.key], model: entry.id)
                let selected = selectUsageWindow(from: windows, preferredLabels: ["5h", "Week", "Day"])
                let usedPercent = selected?.usedPercent ?? estimatedPercent(tokens: estimatedTokens, budgetPerDay: 800_000)
                let weeklyWindow = windows.first(where: { $0.label.caseInsensitiveCompare("Week") == .orderedSame })
                let detail = usageDetailMulti(usedPercent: usedPercent, windows: windows, fallbackLabel: "Day")
                rows.append(MenuUsageRow(id: entry.id, title: entry.title, usedPercent: usedPercent, weeklyPercent: weeklyWindow?.usedPercent, detail: detail))
            }
        }

        if serverManager.isProviderEnabled("ollama") {
            let localModels = serverManager.localModels.filter { $0.isEnabled }
            let localBudgetPerModel = max(1, 2_000_000 / max(1, localModels.count))
            for local in localModels {
                let aliases = localAliases(for: local.name)
                let estimatedTokens = aggregateTokens(stats) { aliases.contains($0.lowercased()) }
                let usedPercent = estimatedPercent(tokens: estimatedTokens, budgetPerDay: localBudgetPerModel)
                let detail = usageDetailMulti(usedPercent: usedPercent, windows: [], fallbackLabel: "Day")
                rows.append(MenuUsageRow(id: "local-\(local.id.uuidString)", title: "Local · \(local.name)", usedPercent: usedPercent, weeklyPercent: nil, detail: detail))
            }
        }

        return rows
    }

    private func hasActiveAccount(_ accountsByType: [ServiceType: [AuthAccount]], _ type: ServiceType) -> Bool {
        (accountsByType[type] ?? []).contains { !$0.isExpired }
    }

    private func loadAccountsByType() -> [ServiceType: [AuthAccount]] {
        let authDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cli-proxy-api")
        var grouped: [ServiceType: [AuthAccount]] = [:]
        for type in ServiceType.allCases {
            grouped[type] = []
        }

        guard let files = try? FileManager.default.contentsOfDirectory(at: authDir, includingPropertiesForKeys: nil) else {
            return grouped
        }

        let formatters: [ISO8601DateFormatter] = {
            let withFractional = ISO8601DateFormatter()
            withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            return [withFractional, standard]
        }()

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let typeRaw = json["type"] as? String,
                  let type = ServiceType.fromAuthType(typeRaw) else {
                continue
            }

            var expiredDate: Date?
            if let expired = json["expired"] as? String {
                for formatter in formatters {
                    if let date = formatter.date(from: expired) {
                        expiredDate = date
                        break
                    }
                }
            }

            let account = AuthAccount(
                id: file.lastPathComponent,
                email: json["email"] as? String,
                login: json["login"] as? String,
                type: type,
                expired: expiredDate,
                filePath: file)
            grouped[type, default: []].append(account)
        }

        return grouped
    }

    private func aggregateTokens(_ stats: [String: StatsClient.ModelStats], include: (String) -> Bool) -> Int {
        var total = 0
        for (model, value) in stats where include(model) {
            total += value.totalTokens
        }
        return total
    }

    private func estimatedPercent(tokens: Int, budgetPerDay: Int) -> Int {
        let budget = max(1, budgetPerDay)
        return min(100, Int(round(Double(tokens) * 100.0 / Double(budget))))
    }

    private func selectUsageWindow(from windows: [ProviderUsageWindow], preferredLabels: [String]) -> ProviderUsageWindow? {
        guard !windows.isEmpty else { return nil }
        for label in preferredLabels {
            if let match = windows.first(where: { $0.label.caseInsensitiveCompare(label) == .orderedSame }) {
                return match
            }
        }
        return windows.first
    }

    private func usageDetailMulti(usedPercent: Int, windows: [ProviderUsageWindow], fallbackLabel: String) -> String {
        if !windows.isEmpty {
            let ordered = windows.sorted { a, b in
                windowOrder(a.label) < windowOrder(b.label)
            }
            let parts = ordered.map { window -> String in
                var text = "\(window.label) \(max(0, 100 - window.usedPercent))%"
                if let resetAt = window.resetAt {
                    text += " ⏱\(timeRemaining(to: resetAt))"
                }
                return text
            }
            return parts.joined(separator: " · ")
        }
        return "\(max(0, 100 - usedPercent))% left · \(fallbackLabel)"
    }

    private func providerWindows(_ snapshot: ProviderUsageSnapshot?, model: String) -> [ProviderUsageWindow] {
        guard let snapshot else { return [] }
        if let modelWindows = snapshot.modelUsages.first(where: { $0.modelName.caseInsensitiveCompare(model) == .orderedSame })?.windows {
            return modelWindows
        }
        return snapshot.windows
    }

    private func windowOrder(_ label: String) -> Int {
        let lower = label.lowercased()
        if lower == "5h" { return 0 }
        if lower == "day" || lower == "24h" { return 1 }
        if lower == "week" || lower == "7d" || lower == "168h" { return 2 }
        return 10
    }

    private func localAliases(for modelName: String) -> Set<String> {
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

    private func timeRemaining(to date: Date) -> String {
        let interval = max(0, Int(date.timeIntervalSinceNow))
        let days = interval / 86_400
        let hours = (interval % 86_400) / 3600
        if days > 0 { return "\(days)d \(hours)h" }
        let minutes = (interval % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
