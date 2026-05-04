# BreakEnforcer

A 20-20-20 break reminder for macOS. Forces a fullscreen break every 20 minutes (look 20 ft away for 20 sec) and a longer 5-minute break every hour (stretch, walk, drink water).

Auto-skips during meetings, presentations, Do Not Disturb, and idle time. Pause from the menu bar when needed.

## Features

- Native macOS app: menu bar icon, settings window, fullscreen break overlay
- 28 random reminders rotating each break: eyes, neck, shoulders, wrists, back, breath, hydrate, pushups, squats, plank, walk, stretch, lunges, and more
- Auto-skip during:
  - Camera in use (Zoom, Google Meet, Teams, FaceTime, Slack huddles, OBS)
  - Keynote or PowerPoint in presenting mode
  - Do Not Disturb / Focus mode on
  - Idle for more than 5 minutes
- Quick pause from menu bar: 30 min, 1 hour, indefinite
- Triple-tap Esc during a break to skip
- Multi-monitor: covers all displays
- Settings stored as JSON, easy to edit
- Logs to `~/Library/Logs/BreakEnforcer.log`

## Requirements

- macOS 11 (Big Sur) or newer, **Apple Silicon** (M1/M2/M3/M4 etc.)
- No other dependencies. Prebuilt binaries are included.

## Install

1. Download the zip and unzip it (Desktop is fine).
2. Double-click **`install.command`**.
3. The first time, macOS will probably block it with this warning:
   > "install.command" cannot be opened because it is from an unidentified developer.

   To get past it:
   - **Right-click** (or hold **Control** and click) on `install.command`
   - Choose **Open** from the menu
   - Click **Open** again in the dialog that appears

   This is a one-time hurdle for unsigned apps. You only need to do it once per machine.
4. The installer copies BreakEnforcer.app to `/Applications`, removes the quarantine flag, and launches the app.
5. Look for the eye icon in your menu bar (top right of screen).

### If the .app itself shows a warning

After install, if double-clicking the app shows:
> "BreakEnforcer" cannot be opened because Apple cannot check it for malicious software.

Open **System Settings → Privacy & Security**, scroll to the message about BreakEnforcer, and click **Open Anyway**. The installer normally strips the quarantine flag to prevent this.

### Auto-start at login

1. Open **System Settings**
2. Go to **General → Login Items & Extensions**
3. Under "Open at Login", click the **+** button
4. Pick **BreakEnforcer** in the Applications folder
5. Click **Open**

## Usage

Click the eye icon in your menu bar:

| Menu item | What it does |
|---|---|
| Status | Shows time until next break, or pause status |
| Test Break (10s) | Preview the break window |
| Pause for 30 minutes | Skip breaks for 30 min |
| Pause for 1 hour | Skip breaks for 1 hour |
| Pause indefinitely | Stop until you click Resume |
| Resume | Resume from any pause |
| Settings | Change intervals (opens window with text fields) |
| Open Log | Diagnostic log |
| Quit Break Enforcer | Fully stops the app |

### During a break

The black screen shows a countdown, headline (LOOK AWAY, ROLL SHOULDERS, etc.), and a tip.

To skip a break: **tap Esc 3 times in a row** within 2 seconds. The hint at the bottom counts down.

(Cmd+Opt+Esc opens macOS Force Quit, but its dialog is hidden behind the break window since the break uses screensaver-level priority. Triple-Esc is the way.)

## Configuration

Settings live at:
```
~/Library/Application Support/BreakEnforcer/config.json
```

Editable via the Settings menu, or directly:

```json
{
  "workIntervalMin": 20,
  "shortBreakSec": 20,
  "longBreakEvery": 3,
  "longBreakMin": 5,
  "preWarningSec": 10
}
```

| Field | Default | Meaning |
|---|---|---|
| `workIntervalMin` | 20 | Minutes between breaks |
| `shortBreakSec` | 20 | Short break length in seconds |
| `longBreakEvery` | 3 | After this many breaks, do a long one |
| `longBreakMin` | 5 | Long break length in minutes |
| `preWarningSec` | 10 | Heads-up notification seconds before break |

Save changes via the Settings window and the daemon restarts automatically.

## Architecture

```
BreakEnforcer.app/
└── Contents/
    ├── Info.plist
    ├── MacOS/
    │   ├── BreakEnforcer       Menu bar app (Swift, native Cocoa)
    │   └── break_window        Fullscreen break overlay (Swift)
    └── Resources/
        ├── menubar.swift       Source for menu bar app
        ├── break_window.swift  Source for break overlay
        └── break_enforcer.py   Timer daemon (Python 3, stdlib only)
```

- **Menu bar app** (Swift): UI, settings window, controls, spawns the Python daemon
- **Python daemon**: timer loop, skip detection, fires the break window via subprocess
- **Break window** (Swift): native NSWindow at `CGShieldingWindowLevel` covering all screens

State / config files:
- `~/.break_enforcer_pause` (pause expiry timestamp)
- `~/Library/Application Support/BreakEnforcer/config.json` (settings)
- `~/Library/Application Support/BreakEnforcer/state.json` (next break time)
- `~/Library/Logs/BreakEnforcer.log` (diagnostic log)

## Build from source

The installer recompiles automatically. To rebuild manually after editing source:

```bash
APP=/Applications/BreakEnforcer.app
swiftc "$APP/Contents/Resources/menubar.swift"      -o "$APP/Contents/MacOS/BreakEnforcer"
swiftc "$APP/Contents/Resources/break_window.swift" -o "$APP/Contents/MacOS/break_window"
```

Then restart:
```bash
pkill -f BreakEnforcer
open /Applications/BreakEnforcer.app
```

## Uninstall

1. Click the menu bar icon → **Quit Break Enforcer**
2. Drag `/Applications/BreakEnforcer.app` to the Trash
3. Optional cleanup:
   ```bash
   rm -rf ~/Library/Application\ Support/BreakEnforcer
   rm -f  ~/Library/Logs/BreakEnforcer.log
   rm -f  ~/.break_enforcer_pause
   ```

## Troubleshooting

**Eye icon doesn't appear after install.**
```bash
pkill -f BreakEnforcer
open /Applications/BreakEnforcer.app
```

**Break fires during a call it should have skipped.**
The skip detection looks for the camera being in active use. Browser tabs in Google Meet, Zoom Web, Teams Web all use the camera, so they should be caught. If a voice-only call slips through, click the menu bar icon and pick "Pause for 30 minutes".

**Can't dismiss the break.**
Tap Esc 3 times rapidly within 2 seconds. The hint at the bottom of the break window confirms each tap.

**Settings change didn't take effect.**
Settings only apply on the next break cycle. Saving in the Settings window auto-restarts the daemon, so it should pick up changes immediately. If not:
```bash
pkill -f break_enforcer.py
open /Applications/BreakEnforcer.app
```

**Logs.**
Click "Open Log" in the menu bar, or:
```bash
tail -f ~/Library/Logs/BreakEnforcer.log
```

## License

MIT. See [LICENSE](LICENSE).
