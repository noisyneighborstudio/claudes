import AppKit

// Claudes — menu bar launcher for Claude profiles (desktop instances + Claude Code CLI).
// Profiles are discovered from /Applications/Claude-*.app and ~/.claude-profiles/.
// Helper scripts are embedded in the app bundle (Contents/Resources).
//
// Resident duties beyond the menu:
//  - Auto-repatch: detects Claude.app updates (version drift vs clones) and
//    silently rebuilds idle clones in the background.
//  - Self-update: checks GitHub releases and offers a one-click update.

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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let fm = FileManager.default
    private let home = NSHomeDirectory()
    private var configRoot: String { home + "/.claude-profiles" }
    private let claudeAppPath = "/Applications/Claude.app"
    private let repoAPI = "https://api.github.com/repos/sethwebster/claudes/releases/latest"

    private var repatchInFlight = Set<String>()
    private var latestVersion: String?
    private var latestAssetURL: URL?
    private var selfUpdating = false
    private var appsDirSource: DispatchSourceFileSystemObject?
    private var repatchDebounce: DispatchWorkItem?
    private var lastUpdateCheck = Date.distantPast

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

        // Self-update check: shortly after launch, then every 6 hours.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { self.checkForSelfUpdate() }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in self.checkForSelfUpdate() }
    }

    // MARK: - Menu construction (rebuilt each time it opens)

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Opportunistic release check on menu open (async; throttled to 5 min)
        // so updates surface within one interaction of shipping, not one timer cycle.
        if Date().timeIntervalSince(lastUpdateCheck) > 300 {
            lastUpdateCheck = Date()
            checkForSelfUpdate()
        }
        menu.removeAllItems()
        let profiles = discoverProfiles()
        let claudeInstalled = fm.fileExists(atPath: claudeAppPath)

        if let v = latestVersion, let _ = latestAssetURL, isNewer(v, than: currentVersion) {
            let title = selfUpdating ? "Updating Claudes…" : "⬇️ Update Claudes to v\(v)"
            let item = actionItem(title, #selector(selfUpdate(_:)), nil)
            if selfUpdating { item.action = nil }
            menu.addItem(item)
            menu.addItem(.separator())
        }

        if !claudeInstalled {
            menu.addItem(NSMenuItem(title: "⚠️ Claude Desktop not installed", action: nil, keyEquivalent: ""))
            menu.addItem(actionItem("Download Claude Desktop…", #selector(downloadClaude(_:)), nil))
            menu.addItem(.separator())
        }

        if profiles.isEmpty {
            menu.addItem(NSMenuItem(title: "No profiles yet", action: nil, keyEquivalent: ""))
        }

        let active = activeProfileName()

        // Once profiles exist, the un-profiled original earns its own entry.
        if !profiles.isEmpty && claudeInstalled {
            let dot = isDefaultRunning() ? "🟢" : "⚪️"
            let item = NSMenuItem(title: "\(dot) Default", action: nil, keyEquivalent: "")
            item.state = active == "Default" ? .on : .off
            let sub = NSMenu()
            if active != "Default" {
                sub.addItem(actionItem("Set as Active (Global)", #selector(setActiveDefault(_:)), nil))
                sub.addItem(.separator())
            }
            sub.addItem(actionItem("Open Desktop App", #selector(openDefaultDesktop(_:)), nil))
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
            sub.addItem(actionItem("Copy Command:  claude-\(profile.name.lowercased())", #selector(copyCommand(_:)), profile.name))
            sub.addItem(actionItem("Reveal Data Dir", #selector(revealData(_:)), profile.name))
            sub.addItem(actionItem("Transfer Session…", #selector(transferProfileSession(_:)), profile.name))
            sub.addItem(.separator())
            sub.addItem(actionItem("Delete Profile…", #selector(deleteProfile(_:)), profile.name))
            item.submenu = sub
            menu.addItem(item)
        }

        menu.addItem(.separator())
        if claudeInstalled {
            menu.addItem(actionItem("New Profile…", #selector(newProfile(_:)), nil))
            menu.addItem(actionItem("Re-patch All (after Claude update)", #selector(repatchAll(_:)), nil))
        }
        let toggle = actionItem("Auto-repatch after Claude updates", #selector(toggleAutoRepatch(_:)), nil)
        toggle.state = autoRepatchEnabled ? .on : .off
        menu.addItem(toggle)
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

    private func discoverProfiles() -> [Profile] {
        var names = Set<String>()
        var withApp = Set<String>()

        if let apps = try? fm.contentsOfDirectory(atPath: "/Applications") {
            for app in apps where app.hasPrefix("Claude-") && app.hasSuffix(".app") {
                let name = String(app.dropFirst("Claude-".count).dropLast(".app".count))
                names.insert(name)
                withApp.insert(name)
            }
        }
        if let cfgs = try? fm.contentsOfDirectory(atPath: configRoot) {
            for cfg in cfgs where !cfg.hasPrefix(".") {
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
              let src = bundleVersion(claudeAppPath),
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
        let busy = !repatchInFlight.isEmpty || selfUpdating
        let updateReady = latestVersion.map { isNewer($0, than: currentVersion) } ?? false
        let suffix = busy ? "⏳" : (staleExists || updateReady ? "⬆️" : "")
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

    // MARK: - Self-update (GitHub releases)

    private func checkForSelfUpdate() {
        var req = URLRequest(url: URL(string: repoAPI)!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let assets = json["assets"] as? [[String: Any]],
                  let zip = assets.first(where: { ($0["name"] as? String) == "Claudes.zip" }),
                  let urlStr = zip["browser_download_url"] as? String,
                  let url = URL(string: urlStr) else { return }
            DispatchQueue.main.async {
                self.latestVersion = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                self.latestAssetURL = url
                self.autoRepatchTickStatusOnly()
            }
        }.resume()
    }

    private func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    @objc private func selfUpdate(_ sender: NSMenuItem) {
        guard let url = latestAssetURL, !selfUpdating else { return }
        selfUpdating = true
        updateStatusTitle(staleExists: false)
        URLSession.shared.downloadTask(with: url) { tmpURL, _, error in
            DispatchQueue.main.async {
                guard let tmpURL = tmpURL, error == nil else {
                    self.selfUpdating = false
                    self.alert("Update download failed", error?.localizedDescription ?? "Unknown error")
                    return
                }
                self.installUpdate(from: tmpURL)
            }
        }.resume()
    }

    private func installUpdate(from zipURL: URL) {
        let staging = NSTemporaryDirectory() + "claudes-update-\(ProcessInfo.processInfo.processIdentifier)"
        let zipPath = staging + "/Claudes.zip"
        do {
            try fm.createDirectory(atPath: staging, withIntermediateDirectories: true)
            if fm.fileExists(atPath: zipPath) { try fm.removeItem(atPath: zipPath) }
            try fm.moveItem(at: zipURL, to: URL(fileURLWithPath: zipPath))
        } catch {
            selfUpdating = false
            alert("Update failed", error.localizedDescription)
            return
        }

        // Unzip, de-quarantine, then hand off to a detached script that swaps
        // the bundle after this process exits and relaunches.
        let script = """
        #!/bin/zsh
        set -e
        cd "\(staging)"
        /usr/bin/ditto -xk Claudes.zip extracted
        [[ -d extracted/Claudes.app ]] || exit 1
        /usr/bin/xattr -dr com.apple.quarantine extracted/Claudes.app 2>/dev/null || true
        sleep 1
        rm -rf "/Applications/Claudes.app"
        /usr/bin/ditto extracted/Claudes.app "/Applications/Claudes.app"
        /usr/bin/open "/Applications/Claudes.app"
        rm -rf "\(staging)"
        """
        let scriptPath = staging + "/update.zsh"
        do {
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/zsh")
            task.arguments = [scriptPath]
            try task.run()
            NSApp.terminate(nil)
        } catch {
            selfUpdating = false
            alert("Update failed", error.localizedDescription)
        }
    }

    // MARK: - Actions

    @objc private func downloadClaude(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(URL(string: "https://claude.ai/download")!)
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
        let effective = name ?? (isDefaultMigrated ? "Default" : nil)
        let invoke = effective.map { "CLAUDE_CONFIG_DIR=\"$HOME/.claude-profiles/\($0)\" claude" } ?? "claude"
        return "if command -v claude >/dev/null 2>&1; then \(invoke); else echo 'Claude Code CLI not found. Install it first: npm install -g @anthropic-ai/claude-code'; fi"
    }

    private func isDefaultRunning() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", claudeAppPath + "/Contents/MacOS/Claude"]
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
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: claudeAppPath),
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
        pb.setString("claude-\(name.lowercased())", forType: .string)
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
        let alert = NSAlert()
        alert.messageText = "New Claude profile"
        alert.informativeText = "Name, letters/numbers only (e.g. Work). Clones Claude.app into an isolated instance with its own login, plus a Claude Code config dir."
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
        if name.lowercased() == "default" {
            self.alert("Reserved name", "“Default” is the un-profiled Claude — it already has a menu entry.")
            return
        }
        if fm.fileExists(atPath: "/Applications/Claude-\(name).app") {
            self.alert("Profile exists", "Claude-\(name).app is already in /Applications. Pick another name, or delete the existing profile first.")
            return
        }
        runInTerminal("\"\(scriptsDir)/make-claude-profile.sh\" \(name)")
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
        let invoke = effectiveDest.map { "CLAUDE_CONFIG_DIR=\"$HOME/.claude-profiles/\($0)\" claude --resume \(session.id)" }
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
