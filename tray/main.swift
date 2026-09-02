import AppKit
#if canImport(Sparkle)
import Sparkle
typealias UpdaterDelegateProtocol = SPUUpdaterDelegate
#else
protocol UpdaterDelegateProtocol {}
#endif

// Claudes — menu bar launcher for Claude profiles (desktop instances + Claude Code CLI).
// Profiles are discovered from /Applications/Claude-*.app and ~/.claude-profiles/.
// Helper scripts are embedded in the app bundle (Contents/Resources).
//
// Resident duties beyond the menu:
//  - Auto-repatch: detects Claude.app updates (version drift vs clones) and
//    silently rebuilds idle clones in the background.
//  - Self-update: delegates signed automatic and manual updates to Sparkle.

struct Profile {
    let name: String
    let hasApp: Bool
    let dataDir: String
    let configDir: String
}

// A Claude Code CLI session: projects/<slug>/<uuid>.jsonl inside a config dir.
struct SessionInfo {
    let id: String
    let projectSlug: String
    let jsonlPath: String
    let cwd: String?
    let snippet: String
    let mtime: Date
}

// Data source for the session picker table (cell-based, single column).
final class SessionListController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var rows: [String] = []
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        rows[row]
    }
}

func appleScriptEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
}

// Known terminals and how to hand each one a command. Only installed ones are shown.
struct TerminalSpec {
    let name: String
    let bundleId: String
    let kind: Kind
    enum Kind {
        case appleScript((String) -> String)   // cmd -> osascript source (needs Automation permission)
        case openArgs((String) -> [String])    // cmd -> CLI args for a new app instance
        case warpLaunchConfig                  // Warp: launch-configuration yaml + warp:// URL
    }
}

let terminalSpecs: [TerminalSpec] = [
    TerminalSpec(name: "Terminal", bundleId: "com.apple.Terminal", kind: .appleScript { cmd in
        "tell application id \"com.apple.Terminal\"\nactivate\ndo script \"\(appleScriptEscape(cmd))\"\nend tell"
    }),
    TerminalSpec(name: "iTerm2", bundleId: "com.googlecode.iterm2", kind: .appleScript { cmd in
        "tell application id \"com.googlecode.iterm2\"\nactivate\nset w to (create window with default profile)\ntell current session of w to write text \"\(appleScriptEscape(cmd))\"\nend tell"
    }),
    TerminalSpec(name: "Warp", bundleId: "dev.warp.Warp-Stable", kind: .warpLaunchConfig),
    TerminalSpec(name: "Ghostty", bundleId: "com.mitchellh.ghostty", kind: .openArgs { cmd in
        ["-e", "/bin/zsh", "-lc", cmd]
    }),
    TerminalSpec(name: "kitty", bundleId: "net.kovidgoyal.kitty", kind: .openArgs { cmd in
        ["/bin/zsh", "-lc", cmd]
    }),
    TerminalSpec(name: "Alacritty", bundleId: "org.alacritty", kind: .openArgs { cmd in
        ["-e", "/bin/zsh", "-lc", cmd]
    }),
    TerminalSpec(name: "WezTerm", bundleId: "com.github.wez.wezterm", kind: .openArgs { cmd in
        ["start", "--", "/bin/zsh", "-lc", cmd]
    }),
]

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UpdaterDelegateProtocol {
    private var statusItem: NSStatusItem!
    private let fm = FileManager.default
    private let home = NSHomeDirectory()
    private var configRoot: String { home + "/.claude-profiles" }
    private let claudeBundleID = "com.anthropic.claudefordesktop"
    private let newIssueURL = "https://github.com/noisyneighborstudio/claudes/issues/new"

    private var repatchInFlight = Set<String>()
    private var appsDirSource: DispatchSourceFileSystemObject?
    private var repatchDebounce: DispatchWorkItem?
#if canImport(Sparkle)
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil
    )
#endif

    private var autoRepatchEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "autoRepatch") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoRepatch") }
    }

    // Scripts live in the bundle's Resources; fall back to the source tree when
    // running the bare dev binary.
    private var scriptsDir: String {
        if let r = Bundle.main.resourcePath, fm.fileExists(atPath: r + "/make-claude-profile.sh") {
            return r
        }
        return home + "/Development/Claudes"
    }

    // Claude Desktop is not always in /Applications: a per-user install lands in
    // ~/Applications, and the user can point us at any bundle via "Locate Claude
    // Desktop…". Clones carry a suffixed bundle id, so the base id never matches one.
    private var claudeAppPath: String? {
        if let saved = UserDefaults.standard.string(forKey: "claudeAppPath"),
           fm.fileExists(atPath: saved + "/Contents") {
            return saved
        }
        for candidate in ["/Applications/Claude.app", home + "/Applications/Claude.app"]
        where fm.fileExists(atPath: candidate + "/Contents") {
            return candidate
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleID)?.path
    }

    private var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let r = Bundle.main.resourcePath, let icon = NSImage(contentsOfFile: r + "/claudes.icns") {
            icon.size = NSSize(width: 18, height: 18)
            statusItem.button?.image = icon
            statusItem.button?.imagePosition = .imageLeft
        } else {
            statusItem.button?.title = "🤖"
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Auto-repatch: event-driven — watch /Applications for bundle swaps
        // (Claude's updater renames the new version into place, which modifies
        // the directory). A 6h timer is only a fallback for missed events.
        startWatchingApplications()
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { self.autoRepatchTick() }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in self.autoRepatchTick() }

        // Keep claude-as / claude-<profile> on PATH in step with the profile
        // list — real executables, so apps and scripts get them too, and
        // upgrades from a shell-function-only version heal themselves.
        DispatchQueue.global(qos: .utility).async { self.runCLI(["shims"]) }

#if canImport(Sparkle)
        // Sparkle owns automatic scheduling and signature verification. Both
        // automatic and manual checks obtain their feed from the delegate below.
        _ = updaterController
        updaterController.updater.automaticallyChecksForUpdates = true
#endif
    }

    // MARK: - Menu construction (rebuilt each time it opens)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let profiles = discoverProfiles()
        let desktopPath = claudeAppPath
        let claudeInstalled = desktopPath != nil

        if !claudeInstalled {
            menu.addItem(NSMenuItem(title: "⚠️ Claude Desktop not found — Claude Code profiles still work",
                                    action: nil, keyEquivalent: ""))
            menu.addItem(actionItem("Locate Claude Desktop…", #selector(locateClaude(_:)), nil))
            menu.addItem(actionItem("Download Claude Desktop…", #selector(downloadClaude(_:)), nil))
            menu.addItem(.separator())
        }

        if profiles.isEmpty {
            menu.addItem(NSMenuItem(title: "No profiles yet", action: nil, keyEquivalent: ""))
        }

        let active = activeProfileName()

        // Once profiles exist, the un-profiled original earns its own entry — its
        // CLI half exists whether or not the desktop app is installed.
        if !profiles.isEmpty {
            let dot = isDefaultRunning() ? "🟢" : "⚪️"
            let item = NSMenuItem(title: "\(dot) Default", action: nil, keyEquivalent: "")
            item.state = active == "Default" ? .on : .off
            let sub = NSMenu()
            if active != "Default" {
                sub.addItem(actionItem("Set as Active (Global)", #selector(setActiveDefault(_:)), nil))
                sub.addItem(.separator())
            }
            if claudeInstalled {
                sub.addItem(actionItem("Open Desktop App", #selector(openDefaultDesktop(_:)), nil))
            }
            sub.addItem(actionItem("Open Claude Code (\(preferredTerminal.name))", #selector(openDefaultTerminal(_:)), nil))
            let dTerms = installedTerminals()
            if dTerms.count > 1 {
                let inItem = NSMenuItem(title: "Open Claude Code In", action: nil, keyEquivalent: "")
                let inMenu = NSMenu()
                for t in dTerms {
                    inMenu.addItem(actionItem(t.name, #selector(openDefaultTerminalIn(_:)), t.bundleId))
                }
                inItem.submenu = inMenu
                sub.addItem(inItem)
            }
            sub.addItem(actionItem("Copy Command:  claude", #selector(copyDefaultCommand(_:)), nil))
            sub.addItem(actionItem("Reveal Data Dir", #selector(revealDefaultData(_:)), nil))
            sub.addItem(actionItem("Transfer Session…", #selector(transferDefaultSession(_:)), nil))
            item.submenu = sub
            menu.addItem(item)
        }

        for profile in profiles {
            var marker = isRunning(profile) ? "🟢" : "⚪️"
            var suffix = ""
            if repatchInFlight.contains(profile.name) {
                marker = "⏳"
                suffix = "  (repatching…)"
            } else if isStale(profile) {
                suffix = "  ⬆️ update pending"
            }
            let item = NSMenuItem(title: "\(marker) \(profile.name)\(suffix)", action: nil, keyEquivalent: "")
            item.state = active == profile.name ? .on : .off
            let sub = NSMenu()
            if active != profile.name {
                sub.addItem(actionItem("Set as Active (Global)", #selector(setActiveProfile(_:)), profile.name))
                sub.addItem(.separator())
            }
            if profile.hasApp {
                sub.addItem(actionItem("Open Desktop App", #selector(openDesktop(_:)), profile.name))
            }
            sub.addItem(actionItem("Open Claude Code (\(preferredTerminal.name))", #selector(openTerminal(_:)), profile.name))
            let terms = installedTerminals()
            if terms.count > 1 {
                let inItem = NSMenuItem(title: "Open Claude Code In", action: nil, keyEquivalent: "")
                let inMenu = NSMenu()
                for t in terms {
                    inMenu.addItem(actionItem(t.name, #selector(openTerminalIn(_:)), profile.name + "|" + t.bundleId))
                }
                inItem.submenu = inMenu
                sub.addItem(inItem)
            }
            sub.addItem(actionItem("Copy Command:  \(profileCommand(profile.name))", #selector(copyCommand(_:)), profile.name))
            sub.addItem(actionItem("Reveal Data Dir", #selector(revealData(_:)), profile.name))
            sub.addItem(actionItem("Transfer Session…", #selector(transferProfileSession(_:)), profile.name))
            sub.addItem(.separator())
            sub.addItem(actionItem("Delete Profile…", #selector(deleteProfile(_:)), profile.name))
            item.submenu = sub
            menu.addItem(item)
        }

        menu.addItem(.separator())
        // Without Claude Desktop there is nothing to clone, but a Claude Code
        // profile is just a config dir — creating one must stay possible.
        menu.addItem(actionItem(claudeInstalled ? "New Profile…" : "New Profile (Claude Code only)…",
                                #selector(newProfile(_:)), nil))
        if claudeInstalled {
            menu.addItem(actionItem("Re-patch All (after Claude update)", #selector(repatchAll(_:)), nil))
        }
        let toggle = actionItem("Auto-repatch after Claude updates", #selector(toggleAutoRepatch(_:)), nil)
        toggle.state = autoRepatchEnabled ? .on : .off
        menu.addItem(toggle)
        let channelItem = NSMenuItem(title: "Update Channel", action: nil, keyEquivalent: "")
        let channelMenu = NSMenu()
        for channel in UpdateChannel.allCases {
            let item = actionItem(channel.rawValue.capitalized, #selector(selectUpdateChannel(_:)), channel.rawValue)
            item.state = channel == UpdateChannel.selected() ? .on : .off
            channelMenu.addItem(item)
        }
        channelItem.submenu = channelMenu
        menu.addItem(channelItem)
        menu.addItem(actionItem("Check for Claudes Updates…", #selector(checkForUpdates(_:)), nil))
        let allTerms = installedTerminals()
        if allTerms.count > 1 {
            let termItem = NSMenuItem(title: "Open Sessions In", action: nil, keyEquivalent: "")
            let termMenu = NSMenu()
            for t in allTerms {
                let i = actionItem(t.name, #selector(setPreferredTerminal(_:)), t.bundleId)
                i.state = (t.bundleId == preferredTerminal.bundleId) ? .on : .off
                termMenu.addItem(i)
            }
            termItem.submenu = termMenu
            menu.addItem(termItem)
        }
        menu.addItem(.separator())
        menu.addItem(actionItem("Report a Bug…", #selector(reportBug(_:)), nil))
        let versionItem = NSMenuItem(title: "Claudes v\(currentVersion)", action: nil, keyEquivalent: "")
        menu.addItem(versionItem)
        menu.addItem(NSMenuItem(title: "Quit Claudes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func actionItem(_ title: String, _ action: Selector, _ profile: String?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = profile
        return item
    }

    // MARK: - Profile discovery

    private func isValidProfileName(_ name: String) -> Bool {
        let reserved = ["default"]
        return !reserved.contains(name.lowercased())
            && name.range(of: #"^[A-Za-z0-9]+$"#, options: .regularExpression) != nil
    }

    private func discoverProfiles() -> [Profile] {
        var names = Set<String>()
        var withApp = Set<String>()

        if let apps = try? fm.contentsOfDirectory(atPath: "/Applications") {
            for app in apps where app.hasPrefix("Claude-") && app.hasSuffix(".app") {
                let name = String(app.dropFirst("Claude-".count).dropLast(".app".count))
                guard isValidProfileName(name) else { continue }
                names.insert(name)
                withApp.insert(name)
            }
        }
        // "Default" (the migrated ~/.claude) is the dedicated menu entry, not a profile.
        if let cfgs = try? fm.contentsOfDirectory(atPath: configRoot) {
            for cfg in cfgs where isValidProfileName(cfg) {
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: configRoot + "/" + cfg, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }
                names.insert(cfg)
            }
        }

        return names.sorted().map { name in
            Profile(
                name: name,
                hasApp: withApp.contains(name),
                dataDir: home + "/Library/Application Support/Claude-" + name,
                configDir: configRoot + "/" + name
            )
        }
    }

    private func isRunning(_ profile: Profile) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", "user-data-dir=" + profile.dataDir]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func profile(from sender: NSMenuItem) -> Profile? {
        guard let name = sender.representedObject as? String else { return nil }
        return discoverProfiles().first { $0.name == name }
    }

    // MARK: - Auto-repatch (Claude.app updated -> rebuild idle clones)

    private func startWatchingApplications() {
        let fd = open("/Applications", O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in self?.scheduleDebouncedRepatchCheck() }
        src.setCancelHandler { close(fd) }
        src.resume()
        appsDirSource = src
    }

    // Updates copy a large bundle over several seconds — wait for 30s of quiet
    // before checking versions, so we never clone a half-written Claude.app.
    private func scheduleDebouncedRepatchCheck() {
        repatchDebounce?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.autoRepatchTick() }
        repatchDebounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: item)
    }

    // NSDictionary(contentsOfFile:) instead of Bundle(path:) — Bundle caches
    // Info.plist contents and would miss in-place updates.
    private func bundleVersion(_ appPath: String) -> String? {
        guard let d = NSDictionary(contentsOfFile: appPath + "/Contents/Info.plist") else { return nil }
        return (d["CFBundleShortVersionString"] as? String) ?? (d["CFBundleVersion"] as? String)
    }

    private func isStale(_ profile: Profile) -> Bool {
        guard profile.hasApp,
              let appPath = claudeAppPath,
              let src = bundleVersion(appPath),
              let clone = bundleVersion("/Applications/Claude-\(profile.name).app") else { return false }
        return src != clone
    }

    @objc private func autoRepatchTick() {
        let profiles = discoverProfiles()
        let stale = profiles.filter { isStale($0) }
        updateStatusTitle(staleExists: !stale.isEmpty)
        guard autoRepatchEnabled else { return }
        for p in stale where !isRunning(p) && !repatchInFlight.contains(p.name) {
            backgroundRepatch(p.name)
        }
    }

    private func backgroundRepatch(_ name: String) {
        repatchInFlight.insert(name)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = [scriptsDir + "/repatch-claude-profiles.sh", name]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        task.terminationHandler = { t in
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                self.repatchInFlight.remove(name)
                self.autoRepatchTickStatusOnly()
                if t.terminationStatus != 0 {
                    self.alert("Auto-repatch failed for “\(name)”",
                               "Claude updated but the profile couldn't be rebuilt automatically:\n\n\(String(out.suffix(600)))\n\nTry 🤖 → Re-patch All, or file an issue.")
                }
            }
        }
        do {
            try task.run()
        } catch {
            repatchInFlight.remove(name)
        }
    }

    private func autoRepatchTickStatusOnly() {
        let stale = discoverProfiles().contains { isStale($0) }
        updateStatusTitle(staleExists: stale)
    }

    private func updateStatusTitle(staleExists: Bool) {
        let busy = !repatchInFlight.isEmpty
        let suffix = busy ? "⏳" : (staleExists ? "⬆️" : "")
        if statusItem.button?.image != nil {
            statusItem.button?.title = suffix
        } else {
            statusItem.button?.title = "🤖" + suffix
        }
    }

    @objc private func toggleAutoRepatch(_ sender: NSMenuItem) {
        autoRepatchEnabled.toggle()
        if autoRepatchEnabled { autoRepatchTick() }
    }

    // MARK: - Sparkle update channel

    @objc private func selectUpdateChannel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let channel = UpdateChannel(rawValue: raw) else { return }
        UserDefaults.standard.set(channel.rawValue, forKey: UpdateChannel.preferenceKey)
#if canImport(Sparkle)
        updaterController.updater.resetUpdateCycle()
#endif
    }

    @objc private func checkForUpdates(_ sender: NSMenuItem) {
#if canImport(Sparkle)
        updaterController.checkForUpdates(sender)
#else
        alert("Updates unavailable", "This development build was compiled without Sparkle.")
#endif
    }

#if canImport(Sparkle)
    func feedURLString(for updater: SPUUpdater) -> String? {
        Bundle.main.object(forInfoDictionaryKey: UpdateChannel.selected().feedInfoKey) as? String
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        [UpdateChannel.selected().rawValue]
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        alert("Update check failed", error.localizedDescription)
    }
#endif

    // MARK: - Actions

    // The path is stored in this app's preferences; the claudes CLI reads the same
    // key, so scripts and menu agree on where Claude Desktop lives.
    @objc private func locateClaude(_ sender: NSMenuItem) {
        let panel = NSOpenPanel()
        panel.message = "Select Claude.app"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path
        guard let id = NSDictionary(contentsOfFile: path + "/Contents/Info.plist")?["CFBundleIdentifier"] as? String,
              id == claudeBundleID else {
            alert("Not Claude Desktop", "“\((path as NSString).lastPathComponent)” isn't the Claude Desktop app. Pick Claude.app — a profile clone (Claude-<Name>.app) won't do.")
            return
        }
        UserDefaults.standard.set(path, forKey: "claudeAppPath")
        autoRepatchTick()
    }

    @objc private func downloadClaude(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(URL(string: "https://claude.ai/download")!)
    }

    @objc private func reportBug(_ sender: NSMenuItem) {
        let body = """
        ## What happened?
        <!-- Tell us what went wrong. -->

        ## What did you expect?
        <!-- Tell us what you expected to happen. -->

        ## Steps to reproduce
        1.

        ## Environment
        - Claudes version: \(currentVersion)
        - macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        """
        guard var components = URLComponents(string: newIssueURL) else {
            alert("Couldn't open GitHub Issues", "Visit github.com/noisyneighborstudio/claudes/issues to report the bug.")
            return
        }
        components.queryItems = [
            URLQueryItem(name: "title", value: "[Bug] "),
            URLQueryItem(name: "body", value: body),
        ]
        guard let url = components.url, NSWorkspace.shared.open(url) else {
            alert("Couldn't open GitHub Issues", "Visit github.com/noisyneighborstudio/claudes/issues to report the bug.")
            return
        }
    }

    @objc private func openDesktop(_ sender: NSMenuItem) {
        guard let p = profile(from: sender) else { return }
        if repatchInFlight.contains(p.name) {
            alert("“\(p.name)” is repatching", "Claude updated and this profile is being rebuilt. It'll be back in a moment.")
            return
        }
        let url = URL(fileURLWithPath: "/Applications/Claude-\(p.name).app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if error != nil {
                DispatchQueue.main.async {
                    self.alert("Couldn't launch Claude-\(p.name)",
                               "The app may be mid-repatch or damaged. Try “Re-patch All” from the Claudes menu.")
                }
            }
        }
    }

    // MARK: - claudes CLI (single implementation of profile side effects)

    private var cliPath: String { scriptsDir + "/claudes" }

    @discardableResult
    private func runCLI(_ args: [String]) -> (status: Int32, output: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [cliPath] + args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do { try task.run() } catch { return (-1, error.localizedDescription) }
        task.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (task.terminationStatus, out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // After `claudes use`, ~/.claude is a symlink to the active profile and the
    // original default config lives at ~/.claude-profiles/Default.
    private var isDefaultMigrated: Bool {
        (try? fm.destinationOfSymbolicLink(atPath: home + "/.claude")) != nil
    }

    private func activeProfileName() -> String {
        guard let dest = try? fm.destinationOfSymbolicLink(atPath: home + "/.claude") else { return "Default" }
        return (dest as NSString).lastPathComponent
    }

    @objc private func setActiveDefault(_ sender: NSMenuItem) { setActive("Default") }

    @objc private func setActiveProfile(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        setActive(name)
    }

    private func setActive(_ name: String) {
        let r = runCLI(["use", name])
        if r.status != 0 { alert("Couldn't switch active profile", r.output) }
    }

    // Runs in the user's login shell so their PATH applies. nil name = default config.
    private func sessionCommand(_ name: String?) -> String {
        // Once migrated, "Default" must be pinned explicitly — a bare `claude`
        // would follow the ~/.claude symlink to whatever profile is active.
        // env-prefix + &&/|| so the command is valid in zsh, bash, AND fish
        // (VAR=x cmd and if/then are not) — Terminal/iTerm run the user's shell.
        let effective = name ?? (isDefaultMigrated ? "Default" : nil)
        let invoke = effective.map { "env CLAUDE_CONFIG_DIR=\"$HOME/.claude-profiles/\($0)\" claude" } ?? "claude"
        return "command -v claude >/dev/null 2>&1 && \(invoke) || echo 'Claude Code CLI not found. Install it first: npm install -g @anthropic-ai/claude-code'"
    }

    private func isDefaultRunning() -> Bool {
        guard let appPath = claudeAppPath else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", appPath + "/Contents/MacOS/Claude"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    @objc private func openDefaultDesktop(_ sender: NSMenuItem) {
        guard let appPath = claudeAppPath else {
            alert("Claude Desktop not found", "Install it from claude.ai/download, or point Claudes at it with “Locate Claude Desktop…”.")
            return
        }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: appPath),
                                           configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func openDefaultTerminal(_ sender: NSMenuItem) {
        launchSession(sessionCommand(nil), slug: "Default", in: preferredTerminal)
    }

    @objc private func openDefaultTerminalIn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let spec = terminalSpecs.first(where: { $0.bundleId == id }) else { return }
        launchSession(sessionCommand(nil), slug: "Default", in: spec)
    }

    @objc private func copyDefaultCommand(_ sender: NSMenuItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("claude", forType: .string)
    }

    @objc private func revealDefaultData(_ sender: NSMenuItem) {
        let dir = home + "/Library/Application Support/Claude"
        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
    }

    private func installedTerminals() -> [TerminalSpec] {
        terminalSpecs.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleId) != nil }
    }

    private var preferredTerminal: TerminalSpec {
        let saved = UserDefaults.standard.string(forKey: "preferredTerminal")
        let installed = installedTerminals()
        return installed.first { $0.bundleId == saved } ?? installed.first ?? terminalSpecs[0]
    }

    @objc private func setPreferredTerminal(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        UserDefaults.standard.set(id, forKey: "preferredTerminal")
    }

    @objc private func openTerminal(_ sender: NSMenuItem) {
        guard let p = profile(from: sender) else { return }
        launchSession(sessionCommand(p.name), slug: p.name, in: preferredTerminal)
    }

    @objc private func openTerminalIn(_ sender: NSMenuItem) {
        guard let combo = sender.representedObject as? String else { return }
        let parts = combo.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let spec = terminalSpecs.first(where: { $0.bundleId == parts[1] }) else { return }
        launchSession(sessionCommand(parts[0]), slug: parts[0], in: spec)
    }

    @objc private func copyCommand(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(profileCommand(name), forType: .string)
    }

    private func profileCommand(_ name: String) -> String {
        name.lowercased() == "as" ? "claude-as \(name)" : "claude-\(name.lowercased())"
    }

    private func launchSession(_ cmd: String, slug: String, in term: TerminalSpec) {
        switch term.kind {
        case .appleScript(let sourceBuilder):
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", sourceBuilder(cmd)]
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
                task.waitUntilExit()
                if task.terminationStatus != 0 { automationDeniedAlert(appName: term.name) }
            } catch {
                automationDeniedAlert(appName: term.name)
            }
        case .openArgs(let argsBuilder):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: term.bundleId) else { return }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.createsNewApplicationInstance = true
            cfg.activates = true
            cfg.arguments = argsBuilder(cmd)
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { runningApp, error in
                DispatchQueue.main.async {
                    if let error = error {
                        self.alert("Couldn't open \(term.name)", error.localizedDescription)
                    } else {
                        // A second app instance can open behind the existing one —
                        // bring the new window forward explicitly.
                        runningApp?.activate(options: [.activateIgnoringOtherApps])
                    }
                }
            }
        case .warpLaunchConfig:
            // Warp has no AppleScript/CLI-args path; its supported mechanism is a
            // launch-configuration yaml opened via the warp:// URL scheme.
            let dir = home + "/.warp/launch_configurations"
            let fileName = "claudes-\(slug).yaml"
            let yaml = """
            name: claudes-\(slug)
            windows:
              - tabs:
                  - title: Claude \(slug)
                    layout:
                      cwd: "\(home)"
                      commands:
                        - exec: >-
                            \(cmd)
            """
            do {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try yaml.write(toFile: dir + "/" + fileName, atomically: true, encoding: .utf8)
                NSWorkspace.shared.open(URL(string: "warp://launch/\(fileName)")!)
            } catch {
                alert("Couldn't open Warp", error.localizedDescription)
            }
        }
    }

    @objc private func revealData(_ sender: NSMenuItem) {
        guard let p = profile(from: sender) else { return }
        try? fm.createDirectory(atPath: p.dataDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: p.dataDir))
    }

    @objc private func newProfile(_ sender: NSMenuItem) {
        let cliOnly = claudeAppPath == nil
        let alert = NSAlert()
        alert.messageText = cliOnly ? "New Claude Code profile" : "New Claude profile"
        alert.informativeText = cliOnly
            ? "Name, letters/numbers only (e.g. Work). Creates a Claude Code config dir with its own login. Claude Desktop isn't installed, so there's no desktop app to clone — install it later and create the profile again to add one."
            : "Name, letters/numbers only (e.g. Work). Clones Claude.app into an isolated instance with its own login, plus a Claude Code config dir."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.allSatisfy({ ($0.isLetter || $0.isNumber) && $0.isASCII }) else {
            self.alert("Invalid name", "Use ASCII letters and numbers only, e.g. Work or Client2.")
            return
        }
        if ["as", "default"].contains(name.lowercased()) {
            self.alert("Reserved name", "“\(name)” conflicts with a built-in Claudes command. Pick another name.")
            return
        }
        if fm.fileExists(atPath: "/Applications/Claude-\(name).app") {
            self.alert("Profile exists", "Claude-\(name).app is already in /Applications. Pick another name, or delete the existing profile first.")
            return
        }
        if cliOnly {
            let r = runCLI(["new", name, "--cli-only"])
            if r.status != 0 { self.alert("Couldn't create profile", r.output) }
            return
        }
        runInTerminal("\"\(scriptsDir)/claudes\" new \(name)")
    }

    @objc private func repatchAll(_ sender: NSMenuItem) {
        runInTerminal("\"\(scriptsDir)/repatch-claude-profiles.sh\"")
    }

    @objc private func deleteProfile(_ sender: NSMenuItem) {
        guard let p = profile(from: sender) else { return }
        if isRunning(p) {
            alert("“\(p.name)” is running", "Quit that Claude instance first, then delete the profile.")
            return
        }
        if repatchInFlight.contains(p.name) {
            alert("“\(p.name)” is repatching", "Wait for the rebuild to finish, then delete.")
            return
        }
        let confirm = NSAlert()
        confirm.messageText = "Delete profile “\(p.name)”?"
        confirm.informativeText = "“Everything” also removes its login/data (\(p.dataDir)) and CLI config (\(p.configDir)). This can't be undone."
        confirm.addButton(withTitle: "Delete App Only")
        confirm.addButton(withTitle: "Delete Everything")
        confirm.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        let choice = confirm.runModal()
        guard choice != .alertThirdButtonReturn else { return }

        var args = ["delete", p.name, "--yes"]
        if choice == .alertSecondButtonReturn { args.append("--everything") }
        let result = runCLI(args)
        if result.status != 0 {
            alert("Delete failed", result.output)
        }
    }

    // MARK: - Session transfer (move a CLI session between profile config dirs)

    private func configDir(forProfileNamed name: String?) -> String {
        if let name = name { return configRoot + "/" + name }
        return isDefaultMigrated ? configRoot + "/Default" : home + "/.claude"
    }

    @objc private func transferDefaultSession(_ sender: NSMenuItem) {
        transferUI(fromName: nil)
    }

    @objc private func transferProfileSession(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        transferUI(fromName: name)
    }

    private func discoverSessions(configDir: String) -> [SessionInfo] {
        let projectsDir = configDir + "/projects"
        var sessions: [SessionInfo] = []
        guard let slugs = try? fm.contentsOfDirectory(atPath: projectsDir) else { return [] }
        for slug in slugs where !slug.hasPrefix(".") {
            let dir = projectsDir + "/" + slug
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                let path = dir + "/" + file
                let mtime = ((try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? .distantPast
                let (cwd, snippet) = sessionPreview(path)
                sessions.append(SessionInfo(id: String(file.dropLast(".jsonl".count)),
                                            projectSlug: slug, jsonlPath: path,
                                            cwd: cwd, snippet: snippet, mtime: mtime))
            }
        }
        return sessions.sorted { $0.mtime > $1.mtime }
    }

    // Read the head of the transcript for the working dir and first user prompt.
    private func sessionPreview(_ path: String) -> (cwd: String?, snippet: String) {
        guard let fh = FileHandle(forReadingAtPath: path) else { return (nil, "") }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: 16384),
              let text = String(data: data, encoding: .utf8) else { return (nil, "") }
        var cwd: String?
        var snippet: String?
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if cwd == nil { cwd = obj["cwd"] as? String }
            if snippet == nil, obj["type"] as? String == "user",
               let msg = obj["message"] as? [String: Any] {
                if let s = msg["content"] as? String {
                    snippet = s
                } else if let parts = msg["content"] as? [[String: Any]] {
                    snippet = parts.compactMap { $0["text"] as? String }.first
                }
            }
            if cwd != nil && snippet != nil { break }
        }
        let clean = (snippet ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return (cwd, clean.isEmpty ? "(no prompt)" : String(clean.prefix(80)))
    }

    private func sessionRowLabel(_ s: SessionInfo) -> String {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        let project = s.cwd.map { ($0 as NSString).lastPathComponent } ?? s.projectSlug
        return "\(df.string(from: s.mtime))  ·  \(project)  ·  \(s.snippet)"
    }

    private func transferUI(fromName: String?) {
        let srcCfg = configDir(forProfileNamed: fromName)
        let srcLabel = fromName ?? "Default"
        let sessions = discoverSessions(configDir: srcCfg)
        guard !sessions.isEmpty else {
            alert("No sessions in “\(srcLabel)”", "This profile has no Claude Code sessions yet.")
            return
        }
        var targets: [(name: String?, label: String)] = []
        if fromName != nil { targets.append((nil, "Default")) }
        for p in discoverProfiles() where p.name != fromName {
            targets.append((p.name, p.name))
        }
        guard !targets.isEmpty else {
            alert("No destination profile", "Create another profile first (🤖 → New Profile…).")
            return
        }

        let controller = SessionListController()
        controller.rows = sessions.map { sessionRowLabel($0) }
        let table = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        column.width = 460
        table.addTableColumn(column)
        table.headerView = nil
        table.usesAlternatingRowBackgroundColors = true
        table.allowsEmptySelection = false
        table.dataSource = controller
        table.delegate = controller
        table.reloadData()
        table.selectRowIndexes([0], byExtendingSelection: false)

        // Explicit frames — an NSScrollView has no intrinsic size, so
        // stack-view/Auto Layout collapses it to zero inside an NSAlert.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 262))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 34, width: 480, height: 228))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let destLabel = NSTextField(labelWithString: "Transfer to:")
        destLabel.sizeToFit()
        destLabel.setFrameOrigin(NSPoint(x: 0, y: 7))
        let popup = NSPopUpButton(frame: NSRect(x: destLabel.frame.maxX + 8, y: 1, width: 220, height: 26),
                                  pullsDown: false)
        popup.addItems(withTitles: targets.map { $0.label })
        container.addSubview(scroll)
        container.addSubview(destLabel)
        container.addSubview(popup)

        let dialog = NSAlert()
        dialog.messageText = "Transfer a session from “\(srcLabel)”"
        dialog.informativeText = "Moves the session (transcript + per-session data) to another profile. Resume it there from this menu or with claude --resume."
        dialog.accessoryView = container
        dialog.addButton(withTitle: "Transfer")
        dialog.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard dialog.runModal() == .alertFirstButtonReturn else { return }

        let session = sessions[max(0, table.selectedRow)]
        let dest = targets[max(0, popup.indexOfSelectedItem)]
        let result = runCLI(["transfer", session.id, "--from", srcLabel, "--to", dest.label])
        guard result.status == 0 else {
            alert("Transfer failed", result.output)
            return
        }

        let effectiveDest = dest.name ?? (isDefaultMigrated ? "Default" : nil)
        let invoke = effectiveDest.map { "env CLAUDE_CONFIG_DIR=\"$HOME/.claude-profiles/\($0)\" claude --resume \(session.id)" }
            ?? "claude --resume \(session.id)"
        let resumeCmd = session.cwd.map { "cd \"\($0)\" && \(invoke)" } ?? invoke

        let done = NSAlert()
        done.messageText = "Session transferred to “\(dest.label)”"
        done.informativeText = "Open it now, or copy the resume command for later."
        done.addButton(withTitle: "Open Now")
        done.addButton(withTitle: "Copy Command")
        done.addButton(withTitle: "Done")
        NSApp.activate(ignoringOtherApps: true)
        switch done.runModal() {
        case .alertFirstButtonReturn:
            launchSession(resumeCmd, slug: dest.label, in: preferredTerminal)
        case .alertSecondButtonReturn:
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(resumeCmd, forType: .string)
        default:
            break
        }
    }

    // MARK: - Terminal + alerts

    // Runs in Terminal.app so script output/progress is visible to the user.
    private func runInTerminal(_ command: String) {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "tell application \"Terminal\"\nactivate\ndo script \"\(escaped)\"\nend tell"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", source]
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus != 0 {
                automationDeniedAlert()
            }
        } catch {
            automationDeniedAlert()
        }
    }

    private func automationDeniedAlert(appName: String = "Terminal") {
        let alert = NSAlert()
        alert.messageText = "Claudes can't control \(appName)"
        alert.informativeText = "macOS blocked Claudes from controlling \(appName). Enable it under Privacy & Security → Automation → Claudes → \(appName), then try again."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
        }
    }

    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
