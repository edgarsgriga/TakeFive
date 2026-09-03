# Changelog

## 0.3.0 - 2026-09-03

### Added
- Hourly squats. `SQUATS` is pulled out of the random long-break pool and pinned
  to one long break per hour. The app claims whichever long break lands nearest
  each hourly mark, so the rate holds at one per hour on any interval setting
  rather than drifting a cycle late. Persisted as `lastSquatsAt` in `state.json`,
  so restarting the app does not hand out a second squats break minutes later.
- Settings checkbox: "Always squats on the first long break each hour".
  New config key `squatsEveryHour`, default `true`.
- Exercise list in the README, all 28 reminders with what each one asks for.

### Fixed
- Breaks fired straight through live calls, screen shares and recordings. Two
  separate causes, both in the camera check:
  - It looked for a hardcoded `appleh13camerad`. The daemon is named after the
    image processor, so an M4 runs `appleh16camerad` and the check never
    matched anything on current Apple Silicon.
  - Widening that match would have been worse. On this hardware the daemon is
    persistent, not spawned on demand: measured at 27 days of uptime with the
    camera off. Treating its existence as "camera in use" would have
    suppressed every break forever.
  Camera process detection is therefore gone on Apple Silicon. Detection now
  reads the power assertion table, which needs no extra permissions:
  - Microphone held by any process, which covers every real call including
    audio-only and camera-off, in Zoom, Meet, Teams, Slack, Discord and
    FaceTime alike, plus voice recording. The skip reason names the app.
  - A meeting, presentation or recording app holding the display awake, which
    catches a screen share with the mic muted.
  - macOS `screencapture` running, for built-in screen recording.
  Deliberately not a blanket display-assertion rule: a browser playing video
  holds the same assertion, and watching a video should not cancel breaks.
  Browser calls are caught by the microphone check instead.
- The menu bar's "Auto-skip" hint reimplemented the checks in Swift and had
  drifted to knowing only about the camera and Keynote, so it could report
  nothing while the daemon was skipping for another reason. It now asks the
  daemon via a new `skipreason` subcommand, leaving one implementation.
- Test Break froze the menu bar app for the full 12 seconds of the test break.
  The menu action waited on the daemon subprocess from the main thread. It is
  now fire and forget.
- A crashed daemon showed a live "Next break in 4:12" countdown. `state.json`
  outlives the process, and `statusText` read it before checking liveness, so
  the menu advertised a break that could never fire. Liveness is checked first.
- Opening the menu could hang the whole app. The Keynote check ran `osascript`
  with no timeout on the main thread, and an unresponsive Keynote holds the
  AppleEvent reply indefinitely. Added a bounded 3s wait that kills the
  straggler, matching the timeouts the Python side already had.
- Settings showed discarded edits. The window was built once and cached, so
  typing a value, clicking Cancel and reopening presented the abandoned input
  as the saved setting. The window is rebuilt from `config.json` on each open.
- Log lines from the menu bar app and the daemon could overwrite each other.
  Both writers opened the same file and tracked their own offset. Both now use
  `O_APPEND`, which is atomic.
- `say -v Samantha` exits silently on Macs where that voice is not installed,
  losing the spoken cue with no indication why. The voice is resolved once at
  startup and falls back to the system default.
- `Info.plist` said version 1.0 and `LSMinimumSystemVersion` 10.13, neither
  true: the project is 0.3.0 and the SF Symbol menu bar icon needs macOS 11.
- Added `NSAppleEventsUsageDescription`. Without it macOS can deny the
  AppleEvents behind the Keynote, PowerPoint and Zoom checks, which would make
  those auto-skips fail silently.
- Replaced unread `Pipe()` objects with `FileHandle.nullDevice` on
  fire-and-forget subprocesses.

### Changed
- The menu bar no longer runs the skip checks on the main thread. Asking the
  daemon was the right call (one implementation instead of two that drift) but
  the first version did it synchronously while the menu was opening, which
  meant a Python start-up plus `pmset`, `pgrep` and AppleScript round trips
  before the menu could draw. It now shows the last known reason, which the
  daemon publishes to `state.json`, and refreshes in the background.
- `say -v '?'` no longer runs at import. It enumerates every installed voice,
  and it was firing on every invocation including `pause`, `status` and the
  menu's `skipreason` call, none of which speak. Resolved on first use.
- Replaced the poll-and-sleep wait in the Swift subprocess helper with a
  termination handler and semaphore. No polling, no added latency.
- "Not running" no longer appears for a working daemon that this menu bar
  instance did not spawn; it falls back to a process check.
- Dropped the Zoom AppleScript probe. A Zoom meeting always holds the
  microphone, so the assertion check already covers it without the round trip
  or the Automation permission. Dropped the Intel-only camera daemon check,
  which cannot match on an Apple Silicon build.
- Squats now route through the same selector as the random prompts, so "never
  the same headline twice in a row" holds across both paths.
- One `state.json` read on start instead of two, so the resumed break count
  and last squats time cannot come from different snapshots. Swift's copy of
  the state schema no longer silently omits fields.
- Collapsed six copies of the pgrep idiom into one helper, and the two
  independent parsers of `pmset` output into one.
- New optional `busyApps` config key, a list of extra app-name fragments to
  treat as busy. Adding an app no longer means editing the source.
- Prompts never repeat back to back. Previously `random.choice` could show the
  same headline twice in a row.
- No more "Break in 0s" heads-up notification when `preWarningSec` is 0.
- The log rotates at 1 MB to `TakeFive.log.1` instead of growing forever.

## 0.2.0 - 2026-05-04

### Renamed
- Project renamed from "BreakEnforcer" to **Take Five**
- Bundle ID: `com.edgarsgriga.takefive`
- Paths moved:
  - `~/Library/Application Support/BreakEnforcer/` → `~/Library/Application Support/TakeFive/`
  - `~/Library/Logs/BreakEnforcer.log` → `~/Library/Logs/TakeFive.log`
  - `~/.break_enforcer_pause` → `~/.takefive_pause`
- New app icon (peach to purple gradient with a bold "5")
- Menu bar icon: `5.circle` SF Symbol

### Fixed (carried over from prior unreleased)
- Skip detection (`pgrep` + `osascript` for camera / Keynote) now runs only when the menu is opened, not every 5 seconds.
- `notify()` no longer breaks if a reminder string contains a quote or backslash.
- `breakCount` now persists across daemon restarts (within 6h) so the long-break cadence is stable.
- Negative `time.sleep` if `preWarningSec` was higher than the work interval.
- `FileHandle!` force-unwrap that crashed the menu bar app on disk-full or permission errors.

### Removed
- Do Not Disturb auto-skip (relied on a brittle heuristic over an undocumented Apple file). Use the Pause menu when in deep focus.

## 0.1.0 - 2026-05-04

Initial release as "BreakEnforcer".
- Menu bar app with status, test break, pause / resume, settings window, quit.
- Native fullscreen break overlay (Swift, Cocoa) at screensaver-window level.
- 28 rotating reminders.
- Auto-skip during meetings, Keynote / PowerPoint presenting, idle.
- Triple-tap Esc to skip a break.
- Multi-monitor support.
- Apple Silicon prebuilt binaries; no Xcode toolchain required to install.
