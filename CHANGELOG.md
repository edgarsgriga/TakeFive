# Changelog

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
