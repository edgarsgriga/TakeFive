// menubar.swift
// Menu bar app for Take Five.
// - Spawns the Python daemon
// - Shows a status icon in the menu bar with controls
// - Provides a Settings window backed by config.json

import Cocoa

// MARK: - Paths
let HOME = NSHomeDirectory()
let APP_SUPPORT = HOME + "/Library/Application Support/TakeFive"
let CONFIG_PATH = APP_SUPPORT + "/config.json"
let STATE_PATH  = APP_SUPPORT + "/state.json"
let PAUSE_PATH  = HOME + "/.takefive_pause"

let RESOURCES   = Bundle.main.resourcePath ?? ""
let SCRIPT_PATH = RESOURCES + "/break_enforcer.py"
let LOG_PATH    = HOME + "/Library/Logs/TakeFive.log"

let APP_TITLE   = "Take Five"

// MARK: - Config
struct Config: Codable {
    var workIntervalMin: Int = 20
    var shortBreakSec: Int = 20
    var longBreakEvery: Int = 3
    var longBreakMin: Int = 5
    var preWarningSec: Int = 10

    static func load() -> Config {
        try? FileManager.default.createDirectory(atPath: APP_SUPPORT, withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: CONFIG_PATH)) else { return Config() }
        return (try? JSONDecoder().decode(Config.self, from: data)) ?? Config()
    }
    func save() {
        try? FileManager.default.createDirectory(atPath: APP_SUPPORT, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: URL(fileURLWithPath: CONFIG_PATH))
        }
    }
}

struct State: Codable {
    var nextBreakAt: TimeInterval = 0
    var breakCount: Int = 0
}
func loadState() -> State {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: STATE_PATH)) else { return State() }
    return (try? JSONDecoder().decode(State.self, from: data)) ?? State()
}

// MARK: - Pause helpers
func pauseInfo() -> (paused: Bool, info: String?) {
    guard let raw = try? String(contentsOfFile: PAUSE_PATH, encoding: .utf8) else { return (false, nil) }
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.isEmpty { return (true, "indefinite") }
    if let exp = TimeInterval(s) {
        let now = Date().timeIntervalSince1970
        if now < exp {
            let mins = max(1, Int((exp - now) / 60))
            return (true, "\(mins) min left")
        } else {
            try? FileManager.default.removeItem(atPath: PAUSE_PATH)
            return (false, nil)
        }
    }
    return (true, "(unparseable)")
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var pythonProcess: Process?
    var settingsWindow: NSWindow?
    var settingsFields: [NSTextField] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        appendLog("===== menubar launch \(Date()) =====")
        setupStatusBar()
        startDaemon()
        notify("\(APP_TITLE) is running. Click the menu bar icon for controls.")
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopDaemon()
        appendLog("menubar exiting cleanly")
    }

    // Without this, NSApp terminates as soon as there are zero windows open,
    // which is always true for a menu-bar-only app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: Status bar
    func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let img = NSImage(systemSymbolName: "5.circle", accessibilityDescription: APP_TITLE) {
                button.image = img
            } else {
                button.title = "T5"
            }
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshMenu()
    }

    // NSMenuDelegate: rebuild only when the user actually opens the menu.
    // Avoids spawning pgrep/osascript every 5s in the background.
    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshMenu()
    }

    func refreshMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        // Status header (disabled item)
        let header = NSMenuItem(title: statusText(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let skip = currentSkipReason()
        if let s = skip {
            let info = NSMenuItem(title: "Auto-skip: \(s)", action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        }

        menu.addItem(.separator())

        menu.addItem(item("Test Break (10s)", #selector(testBreak), key: "t"))

        menu.addItem(.separator())

        menu.addItem(item("Pause for 30 minutes", #selector(pause30)))
        menu.addItem(item("Pause for 1 hour",     #selector(pause60)))
        menu.addItem(item("Pause indefinitely",   #selector(pauseInfinite)))
        menu.addItem(item("Resume",               #selector(resumeBreaks)))

        menu.addItem(.separator())

        menu.addItem(item("Settings…",            #selector(openSettings), key: ","))
        menu.addItem(item("Open Log",             #selector(openLog)))

        menu.addItem(.separator())

        menu.addItem(item("Quit \(APP_TITLE)",    #selector(quitApp), key: "q"))
    }

    func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        return mi
    }

    func statusText() -> String {
        let (paused, info) = pauseInfo()
        if paused { return "PAUSED · \(info ?? "")" }
        let st = loadState()
        if st.nextBreakAt > 0 {
            let secs = Int(st.nextBreakAt - Date().timeIntervalSince1970)
            if secs > 0 {
                let m = secs / 60, s = secs % 60
                return String(format: "Next break in %d:%02d", m, s)
            }
        }
        if !daemonAlive() { return "Not running" }
        return "Active"
    }

    func currentSkipReason() -> String? {
        if pauseInfo().paused { return nil }   // already shown in header
        if isCameraInUse() { return "camera in use" }
        if isKeynotePresenting() { return "Keynote presenting" }
        return nil
    }

    // MARK: Daemon control
    // Track our spawned daemon directly. Don't rely on pgrep -f, which
    // race-matches against other pgrep callers using the same pattern.
    func daemonAlive() -> Bool {
        guard let p = pythonProcess, p.isRunning else { return false }
        return true
    }

    func startDaemon() {
        // Always kill any orphaned daemon from a prior session.
        let kill = Process()
        kill.launchPath = "/usr/bin/pkill"
        kill.arguments = ["-f", "break_enforcer.py"]
        let null = Pipe()
        kill.standardOutput = null
        kill.standardError = null
        try? kill.run()
        kill.waitUntilExit()
        usleep(200_000)

        let p = Process()
        p.launchPath = "/usr/bin/python3"
        p.arguments = [SCRIPT_PATH]
        if let log = openLogForAppend() {
            p.standardOutput = log
            p.standardError = log
        }
        do {
            try p.run()
            pythonProcess = p
            appendLog("daemon started pid=\(p.processIdentifier)")
        } catch {
            appendLog("FAILED to start daemon: \(error)")
        }
    }

    private func openLogForAppend() -> FileHandle? {
        if !FileManager.default.fileExists(atPath: LOG_PATH) {
            FileManager.default.createFile(atPath: LOG_PATH, contents: nil)
        }
        guard let h = FileHandle(forWritingAtPath: LOG_PATH) else { return nil }
        h.seekToEndOfFile()
        return h
    }

    func stopDaemon() {
        // Terminate our direct child first
        if let p = pythonProcess, p.isRunning {
            p.terminate()
            p.waitUntilExit()
        }
        pythonProcess = nil
        // Belt-and-suspenders: clean up any stragglers
        let p = Process()
        p.launchPath = "/usr/bin/pkill"
        p.arguments = ["-f", "break_enforcer.py"]
        let null = Pipe()
        p.standardOutput = null
        p.standardError = null
        try? p.run()
        p.waitUntilExit()
    }

    @discardableResult
    func runDaemonCmd(_ args: [String]) -> Int32 {
        let p = Process()
        p.launchPath = "/usr/bin/python3"
        p.arguments = [SCRIPT_PATH] + args
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    // MARK: Skip detection (mirrors python checks for the menu hint)
    func isCameraInUse() -> Bool {
        for proc in ["AppleCameraAssistant", "VDCAssistant", "appleh13camerad"] {
            let p = Process()
            p.launchPath = "/usr/bin/pgrep"
            p.arguments = ["-x", proc]
            let null = Pipe(); p.standardOutput = null; p.standardError = null
            do { try p.run() } catch { continue }
            p.waitUntilExit()
            if p.terminationStatus == 0 { return true }
        }
        return false
    }
    func isKeynotePresenting() -> Bool {
        let check = Process()
        check.launchPath = "/usr/bin/pgrep"
        check.arguments = ["-x", "Keynote"]
        let null = Pipe(); check.standardOutput = null; check.standardError = null
        do { try check.run() } catch { return false }
        check.waitUntilExit()
        if check.terminationStatus != 0 { return false }
        let p = Process()
        p.launchPath = "/usr/bin/osascript"
        p.arguments = ["-e", "tell application \"Keynote\" to return playing"]
        let pipe = Pipe(); p.standardOutput = pipe
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.lowercased().contains("true") ?? false
    }

    // MARK: Menu actions
    @objc func testBreak()      { runDaemonCmd(["test"]) }
    @objc func pause30()        { runDaemonCmd(["pause", "30"]); refreshMenu() }
    @objc func pause60()        { runDaemonCmd(["pause", "60"]); refreshMenu() }
    @objc func pauseInfinite()  { runDaemonCmd(["pause"]); refreshMenu() }
    @objc func resumeBreaks()   { runDaemonCmd(["resume"]); refreshMenu() }
    @objc func openLog()        { NSWorkspace.shared.open(URL(fileURLWithPath: LOG_PATH)) }

    // Force-exit so we don't depend on the standard NSApp.terminate flow
    // (which can be blocked by lingering subprocess wait or sheets).
    @objc func quitApp() {
        appendLog("quit clicked at \(Date())")
        stopDaemon()
        // Kill any leftover break window too
        let p = Process()
        p.launchPath = "/usr/bin/pkill"
        p.arguments = ["-f", "break_window"]
        try? p.run()
        p.waitUntilExit()
        exit(0)
    }

    // MARK: Settings window
    @objc func openSettings() {
        if settingsWindow == nil {
            settingsWindow = buildSettingsWindow()
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func buildSettingsWindow() -> NSWindow {
        let cfg = Config.load()
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        w.title = "\(APP_TITLE) Settings"
        w.center()
        w.isReleasedWhenClosed = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        func row(_ label: String, _ value: Int) -> NSTextField {
            let r = NSStackView()
            r.orientation = .horizontal
            r.alignment = .firstBaseline
            r.spacing = 12
            r.distribution = .fill

            let lbl = NSTextField(labelWithString: label)
            lbl.font = NSFont.systemFont(ofSize: 13)
            lbl.alignment = .right
            NSLayoutConstraint.activate([
                lbl.widthAnchor.constraint(equalToConstant: 240)
            ])

            let tf = NSTextField()
            tf.stringValue = "\(value)"
            tf.alignment = .right
            tf.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            NSLayoutConstraint.activate([
                tf.widthAnchor.constraint(equalToConstant: 80)
            ])

            r.addArrangedSubview(lbl)
            r.addArrangedSubview(tf)
            stack.addArrangedSubview(r)
            return tf
        }

        let a = row("Time between breaks (minutes):",      cfg.workIntervalMin)
        let b = row("Short break duration (seconds):",     cfg.shortBreakSec)
        let c = row("Long break after this many breaks:",  cfg.longBreakEvery)
        let d = row("Long break duration (minutes):",      cfg.longBreakMin)
        let e = row("Heads-up notification (seconds):",    cfg.preWarningSec)
        settingsFields = [a, b, c, d, e]

        let hint = NSTextField(labelWithString:
            "Example: 20 / 20 / 3 / 5 = short break every 20 min, every 3rd one becomes a 5-min long break (≈ once per hour).")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 0
        hint.preferredMaxLayoutWidth = 400
        stack.addArrangedSubview(hint)

        let note = NSTextField(labelWithString: "Saving will restart the timer.")
        note.font = NSFont.systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        stack.addArrangedSubview(note)

        let btnRow = NSStackView()
        btnRow.orientation = .horizontal
        btnRow.spacing = 8
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(closeSettings))
        cancel.bezelStyle = .rounded
        let save = NSButton(title: "Save & Restart", target: self, action: #selector(saveSettings))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        btnRow.addArrangedSubview(cancel)
        btnRow.addArrangedSubview(save)
        stack.addArrangedSubview(btnRow)

        w.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: w.contentView!.topAnchor),
            stack.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor),
        ])
        return w
    }

    @objc func closeSettings() { settingsWindow?.close() }

    @objc func saveSettings() {
        var cfg = Config()
        cfg.workIntervalMin = max(1, settingsFields[0].integerValue)
        cfg.shortBreakSec   = max(5, settingsFields[1].integerValue)
        cfg.longBreakEvery  = max(1, settingsFields[2].integerValue)
        cfg.longBreakMin    = max(1, settingsFields[3].integerValue)
        cfg.preWarningSec   = max(0, settingsFields[4].integerValue)
        cfg.save()
        settingsWindow?.close()
        stopDaemon()
        usleep(300_000)
        startDaemon()
        refreshMenu()
        notify("Settings saved. Timer restarted.")
    }
}

// MARK: - Helpers
func notify(_ msg: String) {
    let safe = msg
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    let p = Process()
    p.launchPath = "/usr/bin/osascript"
    p.arguments = ["-e", "display notification \"\(safe)\" with title \"\(APP_TITLE)\""]
    try? p.run()
}

func appendLog(_ msg: String) {
    let line = msg + "\n"
    if let data = line.data(using: .utf8) {
        if let h = FileHandle(forWritingAtPath: LOG_PATH) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            FileManager.default.createFile(atPath: LOG_PATH, contents: data)
        }
    }
}

// MARK: - Run
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
