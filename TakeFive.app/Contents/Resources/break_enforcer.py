#!/usr/bin/env python3
"""
Take Five - 20-20-20 break daemon for macOS

Default: short 20s break every 20 min, long 5-min break every 3rd cycle.
Auto-skips during meetings, presentations, and while idle.

Run normally:
    python3 break_enforcer.py
Pause for 30 min (e.g. before a meeting):
    python3 break_enforcer.py pause 30
Pause indefinitely:
    python3 break_enforcer.py pause
Resume:
    python3 break_enforcer.py resume
Status:
    python3 break_enforcer.py status
Kill from anywhere:
    pkill -f break_enforcer.py
"""

import time
import subprocess
import random
import sys
import os
import signal
import json
import re
from datetime import datetime

# Native fullscreen break window. Compiled from break_window.swift sitting
# next to this file; produces ../MacOS/break_window inside the .app bundle.
HERE = os.path.dirname(os.path.abspath(__file__))
BREAK_WINDOW_BIN = os.path.normpath(os.path.join(HERE, "..", "MacOS", "break_window"))

APP_SUPPORT = os.path.expanduser("~/Library/Application Support/TakeFive")
CONFIG_PATH = os.path.join(APP_SUPPORT, "config.json")
STATE_PATH = os.path.join(APP_SUPPORT, "state.json")


def _load_config():
    try:
        with open(CONFIG_PATH) as f:
            return json.load(f)
    except Exception:
        return {}


def _write_state(next_break_at, break_count, last_squats_at=0, skip_reason=None):
    try:
        os.makedirs(APP_SUPPORT, exist_ok=True)
        with open(STATE_PATH, "w") as f:
            json.dump({
                "nextBreakAt": next_break_at,
                "breakCount": break_count,
                "lastSquatsAt": last_squats_at,
                # Last reason a break was skipped, for the menu bar to show
                # immediately instead of recomputing on the main thread.
                "skipReason": skip_reason,
                "writtenAt": time.time(),
            }, f)
    except Exception:
        pass


def _read_state():
    try:
        with open(STATE_PATH) as f:
            return json.load(f)
    except Exception:
        return None


def _resume_session():
    """Carry breakCount and the last squats time across daemon restarts from a
    single snapshot, so the two can never come from different reads. Discard a
    stale snapshot (>6h) since the user has effectively started a new day."""
    s = _read_state() or {}
    if time.time() - s.get("writtenAt", 0) > 6 * 3600:
        return 0, 0.0
    last_squats = float(s.get("lastSquatsAt", 0) or 0)
    if time.time() - last_squats > SQUATS_INTERVAL:
        last_squats = 0.0
    return int(s.get("breakCount", 0)), last_squats


# === Config (read from config.json, falls back to defaults) ===
_cfg = _load_config()
WORK_INTERVAL    = max(1, _cfg.get("workIntervalMin", 20)) * 60
SHORT_BREAK      = max(5, _cfg.get("shortBreakSec", 20))
LONG_BREAK_EVERY = max(1, _cfg.get("longBreakEvery", 3))
LONG_BREAK       = max(1, _cfg.get("longBreakMin", 5)) * 60
PRE_WARNING      = min(max(0, _cfg.get("preWarningSec", 10)), WORK_INTERVAL - 1)
IDLE_SKIP        = 5 * 60

# Hourly squats anchor. When on, one long break per hour is always squats
# instead of a random pick, so legs get a guaranteed dose no matter how the
# dice fall.
SQUATS_EVERY_HOUR = bool(_cfg.get("squatsEveryHour", True))
SQUATS_INTERVAL   = 3600
# Breaks rarely land exactly on the hour, so claim the break nearest each
# hourly target. Half an interval of slack keeps the long-run rate at one per
# hour instead of drifting a whole cycle late every time.
SQUATS_GRACE      = WORK_INTERVAL // 2

# Extra app-name fragments to treat as "busy", on top of the built-in list.
EXTRA_BUSY_APPS   = tuple(_cfg.get("busyApps", []) or ())

PAUSE_FILE = os.path.expanduser("~/.takefive_pause")
LOG = "[take-five]"

# === Reminder variety ===
SHORT_PROMPTS = [
    ("LOOK AWAY",      "Look 20 feet out a window. Hold it."),
    ("LOOK FAR",       "Find the farthest object in the room. Stare at it."),
    ("BLINK",          "Blink slowly 10 times. Screens dry your eyes."),
    ("EYE CIRCLES",    "Roll eyes clockwise 5x, then counter-clockwise."),
    ("PALM YOUR EYES", "Cup warm palms over closed eyes. 20s of darkness."),
    ("ROLL SHOULDERS", "Roll shoulders back 10 times. Drop them down."),
    ("NECK",           "Tilt head ear to shoulder. Both sides. Slowly."),
    ("WRISTS",         "Rotate wrists in circles. Shake them out."),
    ("STAND UP",       "Just stand. For 20 seconds. That's it."),
    ("BREATHE",        "Inhale 4s. Hold 4s. Exhale 6s. Twice."),
    ("UNCLENCH",       "Drop your jaw. Drop your shoulders. Soften your face."),
    ("ARCH BACK",      "Stand. Hands on lower back. Gently arch backward."),
    ("CALF RAISES",    "On your toes, then heels. 10 reps."),
    ("HYDRATE",        "Drink water. Right now."),
]

LONG_PROMPTS = [
    ("PUSHUPS",         "10 pushups. Wall pushups count. Go."),
    ("PLANK",           "60-second plank. Set a timer on your phone."),
    ("JUMPING JACKS",   "30 jumping jacks. Heart rate up."),
    ("WALK",            "Walk to another room. Or outside. Just move."),
    ("STRETCH",         "Reach high. Fold to your toes. Hold each 20s."),
    ("HYDRATE + WALK",  "Refill water bottle. Walk while you sip."),
    ("YOGA FLOW",       "Sun salutation: fold, plank, cobra, downward dog."),
    ("LIE DOWN",        "Floor. Knees up, lower back flat. One full minute."),
    ("FRESH AIR",       "Step outside. Look at the sky. Breathe deeply."),
    ("DOORWAY STRETCH", "Arms in doorframe, lean forward. 30s each side."),
    ("LUNGES",          "10 lunges per leg. Slow."),
    ("DESK PUSHUPS",    "Lean on desk, 15 incline pushups."),
    ("HIP OPENERS",     "Pigeon pose or figure-4 stretch. Both sides."),
]

# Fired on the hourly long break when squatsEveryHour is on. Kept out of
# LONG_PROMPTS so the random pool cannot serve it a second time in the hour.
SQUATS_PROMPT = ("SQUATS", "20 bodyweight squats. Slow and controlled.")


_last_headline = None


def pick(prompts):
    """Random prompt, never the same headline twice in a row."""
    global _last_headline
    options = [p for p in prompts if p[0] != _last_headline] or list(prompts)
    choice = random.choice(options)
    _last_headline = choice[0]
    return choice


def use(prompt):
    """Record a directly chosen prompt, so the no-repeat rule in pick() spans
    the scheduled path as well as the random one."""
    global _last_headline
    _last_headline = prompt[0]
    return prompt


# === Skip detection ===
#
# Process existence is not a camera signal on Apple Silicon: the per-chip
# appleh*camerad daemon is persistent, not spawned on demand (measured at 27
# days of uptime on an M4 with the camera off), and the chip number in its
# name moves with the hardware. The power assertion table is the reliable,
# permission-free signal instead. coreaudiod publishes an "audio-in" resource
# for as long as anything holds the microphone and names the process that
# asked, which covers every real call including audio-only and camera-off.
# See CHANGELOG 0.3.0.

# Owners of assertions that are always-on system plumbing, never a signal that
# the user is busy.
SYSTEM_ASSERTION_OWNERS = {
    'powerd', 'WindowServer', 'coreaudiod', 'bluetoothd', 'kernel_task',
    'corebrightnessd', 'sharingd', 'controlcenterd',
}

# Apps whose "keep the display awake" assertion means presenting, screen
# sharing or recording. Deliberately not a blanket rule: a browser playing
# video holds the same assertion, and watching a video should not cancel
# breaks. Real calls in a browser are caught by the microphone check instead.
MEDIA_APP_HINTS = (
    'zoom', 'teams', 'webex', 'slack', 'discord', 'facetime', 'ringcentral',
    'gotomeeting', 'bluejeans', 'obs', 'quicktime', 'screenflow', 'loom',
    'cleanshot', 'snagit', 'camtasia', 'descript', 'riverside', 'shottr',
    'screen sharing', 'screensharing', 'keynote', 'powerpoint',
    'quickrecorder', 'screenstudio', 'screencapture',
)


def _pgrep(name, exact=True):
    """One place deciding the flag, the timeout and the exception policy for
    the process-existence idiom."""
    try:
        return subprocess.run(['pgrep', '-x' if exact else '-f', name],
                              capture_output=True, timeout=2).returncode == 0
    except Exception:
        return False


def _power_assertions():
    try:
        return subprocess.run(['pmset', '-g', 'assertions'],
                              capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return ''


def _process_name(pid):
    try:
        out = subprocess.run(['ps', '-o', 'comm=', '-p', str(pid)],
                             capture_output=True, text=True, timeout=2).stdout.strip()
        return os.path.basename(out) or None
    except Exception:
        return None


_ASSERTION_HEADER = re.compile(r'\s*pid (\d+)\((.+?)\):(.*)')
_CREATED_FOR = re.compile(r'Created for PID:\s*(\d+)')


def _parse_assertions(txt):
    """Yield (owner_name, body) per assertion entry.

    An entry is a "   pid N(name): ..." header plus its indented continuation
    lines. Both checks below read the same parse, so they cannot disagree
    about what counts as an entry if pmset's format shifts.
    """
    owner, body = None, []
    for line in txt.splitlines():
        m = _ASSERTION_HEADER.match(line)
        if m:
            if owner is not None:
                yield owner, "\n".join(body)
            owner, body = m.group(2), [m.group(3)]
        elif owner is not None:
            body.append(line)
    if owner is not None:
        yield owner, "\n".join(body)


def mic_holder(assertions=None):
    """Name of the app holding the microphone, or None.

    Returns the requesting app, not coreaudiod which owns the assertion on its
    behalf, so the skip reason can say which app is responsible.
    """
    txt = assertions if assertions is not None else _power_assertions()
    for _owner, body in _parse_assertions(txt):
        if 'Resources:' in body and 'audio-in' in body:
            m = _CREATED_FOR.search(body)
            return (_process_name(m.group(1)) if m else None) or 'unknown app'
    return None


def display_holding_media_app(assertions=None, extra_hints=()):
    """Name of a meeting, screen share or recording app keeping the display
    awake, or None. Catches a muted screen share, which the mic check misses."""
    txt = assertions if assertions is not None else _power_assertions()
    hints = tuple(MEDIA_APP_HINTS) + tuple(h.lower() for h in extra_hints)
    for owner, body in _parse_assertions(txt):
        if 'PreventUserIdleDisplaySleep' not in body:
            continue
        if owner in SYSTEM_ASSERTION_OWNERS:
            continue
        low = owner.lower()
        if any(h in low for h in hints):
            return owner
    return None


def is_screen_being_captured():
    """macOS runs `screencapture` for its own screen recording, and the
    interactive recorder stays resident for the whole take."""
    return _pgrep('screencapture')


def is_keynote_presenting():
    try:
        if not _pgrep('Keynote'):
            return False
        out = subprocess.run(
            ['osascript', '-e', 'tell application "Keynote" to return playing'],
            capture_output=True, text=True, timeout=3
        ).stdout
        return 'true' in out.lower()
    except Exception:
        return False


def is_powerpoint_presenting():
    try:
        if not _pgrep('Microsoft PowerPoint'):
            return False
        out = subprocess.run(
            ['osascript', '-e',
             'tell application "Microsoft PowerPoint" to return slide show window of active presentation is not missing value'],
            capture_output=True, text=True, timeout=3
        ).stdout
        return 'true' in out.lower()
    except Exception:
        return False


def get_idle_seconds():
    try:
        out = subprocess.run(['ioreg', '-c', 'IOHIDSystem'],
                             capture_output=True, text=True, timeout=3).stdout
        for line in out.splitlines():
            if 'HIDIdleTime' in line:
                ns = int(line.split('=')[-1].strip())
                return ns / 1_000_000_000
    except Exception:
        pass
    return 0


def is_paused():
    if not os.path.exists(PAUSE_FILE):
        return False, None
    try:
        with open(PAUSE_FILE) as f:
            content = f.read().strip()
        if not content:
            return True, "indefinite"
        expires = int(content)
        if time.time() < expires:
            mins = max(1, int((expires - time.time()) / 60))
            return True, f"{mins} min remaining"
        os.remove(PAUSE_FILE)
        return False, None
    except Exception:
        return True, "(unparseable)"


def reason_to_skip():
    paused, info = is_paused()
    if paused:
        return f"paused ({info})"

    # One pmset call feeds both assertion checks.
    assertions = _power_assertions()

    holder = mic_holder(assertions)
    if holder:
        return f"microphone in use ({holder})"

    owner = display_holding_media_app(assertions, EXTRA_BUSY_APPS)
    if owner:
        return f"{owner} presenting or recording"

    if is_screen_being_captured():
        return "screen recording in progress"

    # Presenting can happen with no microphone and no display assertion, so
    # these two stay as direct probes. Zoom does not: a meeting always holds
    # the microphone, so the check above covers it without an AppleScript
    # round trip and the Automation permission it needs.
    if is_keynote_presenting():
        return "Keynote presenting"
    if is_powerpoint_presenting():
        return "PowerPoint presenting"

    idle = get_idle_seconds()
    if idle > IDLE_SKIP:
        return f"already idle {int(idle//60)} min"
    return None


# === Feedback ===
def play_sound(name="Glass"):
    subprocess.Popen(['afplay', f'/System/Library/Sounds/{name}.aiff'],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


# Samantha is not installed on every Mac, and `say` just exits silently when
# the voice is missing, so the spoken cue would vanish with no clue why.
# Resolve once at startup and fall back to the system default voice.
def _pick_voice(preferred="Samantha"):
    try:
        out = subprocess.run(['say', '-v', '?'], capture_output=True,
                             text=True, timeout=5).stdout
        for line in out.splitlines():
            if line.split(' ', 1)[0] == preferred:
                return preferred
    except Exception:
        pass
    return None


_VOICE = ...  # unresolved sentinel; enumerating voices is slow, so defer it


def speak(text):
    global _VOICE
    if _VOICE is ...:
        _VOICE = _pick_voice()
    cmd = ['say'] + (['-v', _VOICE] if _VOICE else []) + [text]
    subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def notify(msg, title="Take Five"):
    def esc(s):
        return s.replace("\\", "\\\\").replace('"', '\\"')
    subprocess.Popen(
        ['osascript', '-e',
         f'display notification "{esc(msg)}" with title "{esc(title)}" sound name "Tink"'],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )


# === Break window ===
def show_break(duration, headline, tip):
    """Hand off to the native Swift binary that draws the fullscreen overlay.

    Blocks until the binary exits (when the countdown finishes).
    """
    if not os.path.exists(BREAK_WINDOW_BIN):
        # Binary missing - fall back to a stark Notification Center alert so
        # the break still happens even if compilation hasn't run.
        notify(f"BREAK NOW: {headline} - {tip} ({duration}s)")
        time.sleep(duration)
        return
    try:
        subprocess.run(
            [BREAK_WINDOW_BIN, str(duration), headline, tip],
            timeout=duration + 30,
        )
    except subprocess.TimeoutExpired:
        subprocess.run(['pkill', '-f', 'break_window'])
    play_sound("Hero")


# === CLI subcommands ===
def cli_pause(args):
    if args:
        try:
            mins = int(args[0])
        except ValueError:
            print("Usage: break_enforcer.py pause [minutes]")
            sys.exit(1)
        expires = int(time.time() + mins * 60)
        with open(PAUSE_FILE, 'w') as f:
            f.write(str(expires))
        until = datetime.fromtimestamp(expires).strftime('%H:%M')
        print(f"Paused for {mins} min (until {until}).")
    else:
        with open(PAUSE_FILE, 'w') as f:
            f.write("")
        print("Paused indefinitely. Run 'resume' to restart.")


def cli_resume():
    if os.path.exists(PAUSE_FILE):
        os.remove(PAUSE_FILE)
        print("Resumed.")
    else:
        print("Wasn't paused.")


def cli_status():
    paused, info = is_paused()
    print(f"Status: {'PAUSED (' + info + ')' if paused else 'active'}")
    skip = reason_to_skip()
    if skip and not paused:
        print(f"Right now would skip: {skip}")
    running = subprocess.run(['pgrep', '-f', 'break_enforcer.py'],
                             capture_output=True).returncode == 0
    print(f"Daemon running: {'yes' if running else 'no'}")


def cli_test():
    """Fire a 10-second test break immediately so you can preview it."""
    print("Firing test break in 2 seconds...")
    time.sleep(2)
    play_sound("Glass")
    speak("Test break.")
    headline, tip = pick(SHORT_PROMPTS)
    show_break(10, f"TEST · {headline}", tip)
    print("Test complete.")


def cli_skipreason():
    """Prints the current skip reason, or nothing. The menu bar app calls this
    instead of reimplementing the checks, so the two can never disagree."""
    r = reason_to_skip()
    if r:
        print(r)


def handle_sigint(signum, frame):
    print("\nTake Five stopped. Take care of those eyes.")
    sys.exit(0)


def run():
    signal.signal(signal.SIGINT, handle_sigint)

    print("=" * 64)
    print("  Take Five - 20-20-20 break daemon")
    print(f"  Short break every {WORK_INTERVAL//60} min for {SHORT_BREAK}s")
    print(f"  Long break every {LONG_BREAK_EVERY * (WORK_INTERVAL//60)} min for {LONG_BREAK//60} min")
    if SQUATS_EVERY_HOUR:
        print("  Squats anchored to the first long break of every hour")
    print("  Auto-skips: mic in use, screen share/recording, Keynote/PPT, idle")
    print("  Pause:  python3 break_enforcer.py pause 30")
    print("  Resume: python3 break_enforcer.py resume")
    print("  Stop:   Ctrl+C   (or: pkill -f break_enforcer.py)")
    print("=" * 64)

    break_count, last_squats = _resume_session()
    # Fixed hourly targets, not "an hour since the last one", so a break that
    # lands slightly early doesn't push every later squats break later still.
    next_squats = (last_squats or time.time()) + SQUATS_INTERVAL
    while True:
        _write_state(time.time() + WORK_INTERVAL, break_count, last_squats)

        time.sleep(WORK_INTERVAL - PRE_WARNING)

        skip = reason_to_skip()
        if skip:
            print(f"{LOG} {datetime.now().strftime('%H:%M')} skip pre-warn: {skip}")
            _write_state(time.time() + PRE_WARNING + WORK_INTERVAL,
                         break_count, last_squats, skip)
            time.sleep(PRE_WARNING)
            continue

        if PRE_WARNING:
            notify(f"Break in {PRE_WARNING}s. Wrap up.")
        time.sleep(PRE_WARNING)

        skip = reason_to_skip()
        if skip:
            print(f"{LOG} {datetime.now().strftime('%H:%M')} skip break:    {skip}")
            _write_state(time.time() + WORK_INTERVAL, break_count, last_squats, skip)
            continue

        break_count += 1
        play_sound("Glass")

        if break_count % LONG_BREAK_EVERY == 0:
            now = time.time()
            if SQUATS_EVERY_HOUR and now >= next_squats - SQUATS_GRACE:
                headline, tip = use(SQUATS_PROMPT)
                last_squats = now
                # Step past the target just met, then catch up over any hours
                # missed while the machine was asleep or the app was paused.
                next_squats += SQUATS_INTERVAL
                while next_squats <= now:
                    next_squats += SQUATS_INTERVAL
            else:
                headline, tip = pick(LONG_PROMPTS)
            duration, phrase = LONG_BREAK, f"Long break. {headline.lower()}."
        else:
            headline, tip = pick(SHORT_PROMPTS)
            duration, phrase = SHORT_BREAK, "Look away."

        speak(phrase)
        _write_state(time.time() + WORK_INTERVAL, break_count, last_squats)
        show_break(duration, headline, tip)


if __name__ == "__main__":
    if len(sys.argv) > 1:
        cmd = sys.argv[1]
        rest = sys.argv[2:]
        if   cmd == "pause":  cli_pause(rest)
        elif cmd == "resume": cli_resume()
        elif cmd == "status": cli_status()
        elif cmd == "test":   cli_test()
        elif cmd == "skipreason": cli_skipreason()
        else:
            print(f"Unknown: {cmd}")
            print("Usage: break_enforcer.py [pause [mins] | resume | status | test | skipreason]")
            sys.exit(1)
    else:
        run()
