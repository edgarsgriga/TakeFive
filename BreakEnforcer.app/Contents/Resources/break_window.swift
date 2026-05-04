// break_window.swift
// Fullscreen break overlay for BreakEnforcer.
// Args: <duration_seconds> <headline> <tip>
// Compiled at install time into ../MacOS/break_window.

import Cocoa

let args = CommandLine.arguments
let duration = args.count > 1 ? (Int(args[1]) ?? 20) : 20
let headline = args.count > 2 ? args[2] : "LOOK AWAY"
let tip      = args.count > 3 ? args[3] : "Look 20 feet away."

class Controller: NSObject, NSApplicationDelegate {
    var windows: [NSWindow] = []
    var countdownLabels: [NSTextField] = []
    var hintLabels: [NSTextField] = []
    var remaining: Int
    var timer: Timer?
    var keyMonitor: Any?
    var escTaps: [Date] = []

    init(duration: Int) {
        self.remaining = duration
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Cover every connected display.
        for screen in NSScreen.screens {
            windows.append(makeWindow(for: screen))
        }
        NSCursor.hide()

        // Escape hatch that actually works at this window level: press Esc
        // three times within 2 seconds. We can't use Cmd+Opt+Esc because the
        // system intercepts that for Force Quit (whose dialog appears below
        // our screensaver-level overlay).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let mods = event.modifierFlags
            let cmd = mods.contains(.command)
            let chars = (event.charactersIgnoringModifiers ?? "").lowercased()

            // Triple-Esc to skip
            if event.keyCode == 53 && !event.isARepeat {
                let now = Date()
                self.escTaps = self.escTaps.filter { now.timeIntervalSince($0) < 2.0 }
                self.escTaps.append(now)
                let count = self.escTaps.count
                if count >= 3 {
                    NSApp.terminate(nil)
                    return nil
                }
                // Visual feedback so user knows it's working
                let need = 3 - count
                let msg = "Tap Esc \(need) more time\(need == 1 ? "" : "s") to skip"
                for h in self.hintLabels { h.stringValue = msg }
                return nil
            }

            // Block typical dismiss keys
            if cmd && ["q", "w", "h", "m", "n"].contains(chars) { return nil }
            if event.keyCode == 48 && cmd { return nil } // Cmd+Tab
            return event
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func makeWindow(for screen: NSScreen) -> NSWindow {
        let win = NSWindow(contentRect: screen.frame,
                           styleMask: .borderless,
                           backing: .buffered,
                           defer: false)
        // CGShieldingWindowLevel is the same level the screensaver and login
        // window use - effectively above everything user-facing.
        win.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        win.backgroundColor = .black
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        win.isOpaque = true
        win.hasShadow = false
        win.isMovable = false

        let view = NSView(frame: screen.frame)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        win.contentView = view

        let w = screen.frame.width
        let h = screen.frame.height

        let headlineLabel = NSTextField(labelWithString: headline)
        headlineLabel.font = NSFont.systemFont(ofSize: 80, weight: .bold)
        headlineLabel.textColor = .white
        headlineLabel.alignment = .center
        headlineLabel.isBordered = false
        headlineLabel.drawsBackground = false
        headlineLabel.frame = NSRect(x: 0, y: h * 0.62, width: w, height: 110)
        view.addSubview(headlineLabel)

        let countdown = NSTextField(labelWithString: "\(remaining)")
        countdown.font = NSFont.systemFont(ofSize: 220, weight: .bold)
        countdown.textColor = NSColor(red: 0.22, green: 1.0, blue: 0.08, alpha: 1.0)
        countdown.alignment = .center
        countdown.isBordered = false
        countdown.drawsBackground = false
        countdown.frame = NSRect(x: 0, y: h * 0.30, width: w, height: 250)
        view.addSubview(countdown)
        countdownLabels.append(countdown)

        let tipLabel = NSTextField(labelWithString: tip)
        tipLabel.font = NSFont.systemFont(ofSize: 34, weight: .regular)
        tipLabel.textColor = NSColor(white: 0.8, alpha: 1.0)
        tipLabel.alignment = .center
        tipLabel.isBordered = false
        tipLabel.drawsBackground = false
        tipLabel.maximumNumberOfLines = 3
        tipLabel.frame = NSRect(x: 100, y: h * 0.16, width: w - 200, height: 110)
        view.addSubview(tipLabel)

        let hint = NSTextField(labelWithString: "Tap Esc 3 times to skip this break")
        hint.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        hint.textColor = NSColor(white: 0.45, alpha: 1.0)
        hint.alignment = .center
        hint.isBordered = false
        hint.drawsBackground = false
        hint.frame = NSRect(x: 0, y: 32, width: w, height: 22)
        view.addSubview(hint)
        hintLabels.append(hint)

        win.orderFrontRegardless()
        return win
    }

    func tick() {
        remaining -= 1
        if remaining <= 0 {
            timer?.invalidate()
            if let m = keyMonitor { NSEvent.removeMonitor(m) }
            NSCursor.unhide()
            for w in windows { w.orderOut(nil) }
            NSApp.terminate(nil)
            return
        }
        for label in countdownLabels {
            label.stringValue = "\(remaining)"
            if remaining <= 3 {
                label.textColor = (remaining % 2 == 0)
                    ? NSColor(red: 1.0, green: 0.19, blue: 0.19, alpha: 1.0)
                    : NSColor(red: 0.22, green: 1.0, blue: 0.08, alpha: 1.0)
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller(duration: duration)
app.delegate = controller
app.activate(ignoringOtherApps: true)
app.run()
