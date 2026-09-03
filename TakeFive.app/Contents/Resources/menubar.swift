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
    var squatsEveryHour: Bool = true

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
    var lastSquatsAt: TimeInterval = 0
    var skipReason: String? = nil
    var writtenAt: TimeInterval = 0
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
    var squatsCheckbox: NSButton?
    // Last skip reason computed off the main thread. The menu renders this
    // immediately and triggers a refresh for next time; asking the daemon
    // synchronously here stalled menu opening on a Python cold start.
    var cachedSkipReason: String?
    var skipReasonRefreshing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        rotateLogIfLarge()
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

        let (paused, pauseDetail) = pauseInfo()
        let st = loadState()
        // Seed from what the daemon last published so the first menu open has
        // something real to show before any background refresh finishes.
        if cachedSkipReason == nil { cachedSkipReason = st.skipReason }

        // Status header (disabled item)
        let header = NSMenuItem(title: statusText(paused: paused, detail: pauseDetail, state: st),
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let skip = currentSkipReason(paused: paused)
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

    func statusText(paused: Bool, detail: String?, state st: State) -> String {
        if paused { return "PAUSED · \(detail ?? "")" }
        // Liveness before the countdown: state.json outlives the daemon, so a
        // crashed daemon used to show a timer ticking toward a break that
        // could never fire.
        if !daemonAlive() { return "Not running" }
        if st.nextBreakAt > 0 {
            let secs = Int(st.nextBreakAt - Date().timeIntervalSince1970)
            if secs > 0 {
                let m = secs / 60, s = secs % 60
                return String(format: "Next break in %d:%02d", m, s)
            }
        }
        return "Active"
    }

    // Ask the daemon rather than reimplementing the checks. The Swift copy had
    // already drifted from the Python one (it only knew about the camera and
    // Keynote), so the menu could claim nothing would be skipped while the
    // daemon was skipping for another reason entirely.
    //
    // Returns what was last computed, and kicks off a background refresh. The
    // checks spawn pmset, pgrep and osascript behind a Python start-up, which
    // is far too much to run on the main thread while a menu is opening.
    func currentSkipReason(paused: Bool) -> String? {
        if paused { return nil }   // already shown in the header
        refreshSkipReasonInBackground()
        return cachedSkipReason
    }

    func refreshSkipReasonInBackground() {
        if skipReasonRefreshing { return }
        skipReasonRefreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let out = runCapture("/usr/bin/python3", [SCRIPT_PATH, "skipreason"], timeout: 10)
            let reason = out?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.cachedSkipReason = reason.isEmpty ? nil : reason
                self.skipReasonRefreshing = false
            }
        }
    }

    // MARK: Daemon control
    // Track our spawned daemon directly. Don't rely on pgrep -f, which
    // race-matches against other pgrep callers using the same pattern.
    func daemonAlive() -> Bool {
        if let p = pythonProcess, p.isRunning { return true }
        // Fall back to a process check so a daemon this instance did not spawn
        // is not reported as dead, which would hide the countdown.
        let p = Process()
        p.launchPath = "/usr/bin/pgrep"
        p.arguments = ["-f", "break_enforcer.py"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
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
        if let log = openLogAppending() {
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

    // Fire and forget. Used for "test", which holds a break window on screen
    // for 10s; waiting on it would freeze the menu bar for the whole break.
    func runDaemonCmdDetached(_ args: [String]) {
        let p = Process()
        p.launchPath = "/usr/bin/python3"
        p.arguments = [SCRIPT_PATH] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { appendLog("failed to run \(args): \(error)") }
    }

    // MARK: Menu actions
    @objc func testBreak()      { runDaemonCmdDetached(["test"]) }
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
        // Rebuilt every time so the fields always show what is actually saved.
        // Reusing the cached window meant that after typing and cancelling,
        // reopening showed the discarded edits as if they were live settings.
        settingsWindow?.close()
        settingsWindow = buildSettingsWindow()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func buildSettingsWindow() -> NSWindow {
        let cfg = Config.load()
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
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

        let squats = NSButton(checkboxWithTitle: "Always squats on the first long break each hour",
                              target: nil, action: nil)
        squats.state = cfg.squatsEveryHour ? .on : .off
        squats.font = NSFont.systemFont(ofSize: 13)
        stack.addArrangedSubview(squats)
        squatsCheckbox = squats

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
        cfg.squatsEveryHour = (squatsCheckbox?.state ?? .on) == .on
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

// Run a command and capture stdout, killing it if it overruns `timeout`.
// An unresponsive Keynote can make its AppleEvent reply take arbitrarily long,
// so the wait is always bounded. Callers run this off the main thread.
func runCapture(_ path: String, _ args: [String], timeout: TimeInterval) -> String? {
    let p = Process()
    p.launchPath = path
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }

    let done = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in done.signal() }
    if done.wait(timeout: .now() + timeout) == .timedOut {
        p.terminate()
        if done.wait(timeout: .now() + 0.5) == .timedOut {
            kill(p.processIdentifier, SIGKILL)
        }
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)
}

func notify(_ msg: String) {
    let safe = msg
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    let p = Process()
    p.launchPath = "/usr/bin/osascript"
    p.arguments = ["-e", "display notification \"\(safe)\" with title \"\(APP_TITLE)\""]
    try? p.run()
}

// O_APPEND, not open-and-seek. The daemon holds an inherited handle on this
// same file, and two writers each tracking their own offset were silently
// overwriting each other's lines. Appending is atomic for both.
func openLogAppending() -> FileHandle? {
    let fd = open(LOG_PATH, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    if fd < 0 { return nil }
    return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
}

func appendLog(_ msg: String) {
    guard let data = (msg + "\n").data(using: .utf8), let h = openLogAppending() else { return }
    h.write(data)
    try? h.close()
}

// Keep the log from growing without limit. One skip line every work interval
// adds up over months of uptime.
func rotateLogIfLarge(maxBytes: Int = 1_000_000) {
    let fm = FileManager.default
    guard let attrs = try? fm.attributesOfItem(atPath: LOG_PATH),
          let size = attrs[.size] as? Int, size > maxBytes else { return }
    let old = LOG_PATH + ".1"
    try? fm.removeItem(atPath: old)
    try? fm.moveItem(atPath: LOG_PATH, toPath: old)
}

// MARK: - Run
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
