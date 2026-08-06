import AppKit

// Claudes — menu bar launcher for Claude profiles (desktop instances + Claude Code CLI).
// Profiles are discovered from /Applications/Claude-*.app and ~/.claude-profiles/.
// Helper scripts are embedded in the app bundle (Contents/Resources).

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

    // Scripts live in the bundle's Resources; fall back to the source tree when
    // running the bare dev binary.
    private var scriptsDir: String {
        if let r = Bundle.main.resourcePath, fm.fileExists(atPath: r + "/make-claude-profile.sh") {
            return r
        }
        return home + "/Development/Claudes"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🤖"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - Menu construction (rebuilt each time it opens)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let profiles = discoverProfiles()
        let claudeInstalled = fm.fileExists(atPath: claudeAppPath)

        if !claudeInstalled {
            menu.addItem(NSMenuItem(title: "⚠️ Claude Desktop not installed", action: nil, keyEquivalent: ""))
            menu.addItem(actionItem("Download Claude Desktop…", #selector(downloadClaude(_:)), nil))
            menu.addItem(.separator())
        }

        if profiles.isEmpty {
            menu.addItem(NSMenuItem(title: "No profiles yet", action: nil, keyEquivalent: ""))
        }

        for profile in profiles {
            let dot = isRunning(profile) ? "🟢" : "⚪️"
            let item = NSMenuItem(title: "\(dot) \(profile.name)", action: nil, keyEquivalent: "")
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
        menu.addItem(.separator())
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

    // MARK: - Actions

    @objc private func downloadClaude(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(URL(string: "https://claude.ai/download")!)
    }

    @objc private func openDesktop(_ sender: NSMenuItem) {
        guard let p = profile(from: sender) else { return }
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
