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
        statusItem.button?.title = "🤖"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Auto-repatch: shortly after launch, then every 30 minutes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { self.autoRepatchTick() }
        Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { _ in self.autoRepatchTick() }

        // Self-update check: shortly after launch, then every 6 hours.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { self.checkForSelfUpdate() }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in self.checkForSelfUpdate() }
    }

    // MARK: - Menu construction (rebuilt each time it opens)

    func menuNeedsUpdate(_ menu: NSMenu) {
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
            let sub = NSMenu()
            if profile.hasApp {
                sub.addItem(actionItem("Open Desktop App", #selector(openDesktop(_:)), profile.name))
            }
            sub.addItem(actionItem("Open Terminal (Claude Code)", #selector(openTerminal(_:)), profile.name))
            sub.addItem(actionItem("Reveal Data Dir", #selector(revealData(_:)), profile.name))
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
        statusItem.button?.title = busy ? "🤖⏳" : (staleExists || updateReady ? "🤖⬆️" : "🤖")
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

    @objc private func openTerminal(_ sender: NSMenuItem) {
        guard let p = profile(from: sender) else { return }
        // Runs in the user's login shell inside Terminal, so their PATH applies.
        let cmd = "if command -v claude >/dev/null 2>&1; then CLAUDE_CONFIG_DIR=\"$HOME/.claude-profiles/\(p.name)\" claude; else echo 'Claude Code CLI not found. Install it first: npm install -g @anthropic-ai/claude-code'; fi"
        runInTerminal(cmd)
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

        do {
            let appPath = "/Applications/Claude-\(p.name).app"
            if fm.fileExists(atPath: appPath) {
                try fm.removeItem(atPath: appPath)
            }
            if choice == .alertSecondButtonReturn {
                if fm.fileExists(atPath: p.dataDir) { try fm.removeItem(atPath: p.dataDir) }
                if fm.fileExists(atPath: p.configDir) { try fm.removeItem(atPath: p.configDir) }
            }
        } catch {
            alert("Delete failed", error.localizedDescription)
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

    private func automationDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = "Claudes can't control Terminal"
        alert.informativeText = "macOS blocked Claudes from opening Terminal. Enable it under Privacy & Security → Automation → Claudes → Terminal, then try again."
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
