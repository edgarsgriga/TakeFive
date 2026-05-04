# Changelog

## Unreleased

### Fixed
- Skip detection (`pgrep` + `osascript` for camera / Keynote) now runs only when the menu is opened, not every 5 seconds. Previously this spawned ~3,000 subprocesses per hour in the background.
- `notify()` no longer breaks or runs as AppleScript if a reminder string contains a quote or backslash.
- `breakCount` now persists across daemon restarts (within 6h) so the long-break cadence is stable when the app is restarted.
- Negative `time.sleep` if `preWarningSec` was set higher than the work interval.
- `FileHandle!` force-unwrap that crashed the menu bar app on disk-full or permission errors.

### Removed
- Do Not Disturb auto-skip. The detection relied on a brittle heuristic over `~/Library/DoNotDisturb/DB/Assertions.json`. Use the menu's Pause options when in deep focus.

## 0.1.0 - 2026-05-04

Initial release.
- Menu bar app with status, test break, pause / resume, settings window, quit.
- Native fullscreen break overlay (Swift, Cocoa) at screensaver-window level.
- 28 rotating reminders (eyes, neck, shoulders, wrists, back, breath, hydrate, pushups, squats, plank, walk, stretch, lunges, etc.).
- Auto-skip during meetings (camera in use), Keynote / PowerPoint presenting, and idle (>5 min).
- Triple-tap Esc to skip a break.
- Multi-monitor support.
- Settings persisted as JSON in `~/Library/Application Support/BreakEnforcer/`.
- Apple Silicon prebuilt binaries; no Xcode toolchain required to install.
