#!/usr/bin/env python3
"""
20-20-20 Break Enforcer for macOS

Default: short 20s break every 20 min, long 5-min break every 3rd cycle.
Auto-skips during meetings, presentations, Do Not Disturb, or while idle.

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
from datetime import datetime

# Native fullscreen break window. Compiled from break_window.swift sitting
# next to this file; produces ../MacOS/break_window inside the .app bundle.
HERE = os.path.dirname(os.path.abspath(__file__))
BREAK_WINDOW_BIN = os.path.normpath(os.path.join(HERE, "..", "MacOS", "break_window"))

APP_SUPPORT = os.path.expanduser("~/Library/Application Support/BreakEnforcer")
CONFIG_PATH = os.path.join(APP_SUPPORT, "config.json")
STATE_PATH = os.path.join(APP_SUPPORT, "state.json")


def _load_config():
    try:
        with open(CONFIG_PATH) as f:
            return json.load(f)
    except Exception:
        return {}


def _write_state(next_break_at, break_count):
    try:
        os.makedirs(APP_SUPPORT, exist_ok=True)
        with open(STATE_PATH, "w") as f:
            json.dump({
                "nextBreakAt": next_break_at,
                "breakCount": break_count,
            }, f)
    except Exception:
        pass

# === Config (read from config.json, falls back to defaults) ===
_cfg = _load_config()
WORK_INTERVAL    = max(1, _cfg.get("workIntervalMin", 20)) * 60
SHORT_BREAK      = max(5, _cfg.get("shortBreakSec", 20))
LONG_BREAK_EVERY = max(1, _cfg.get("longBreakEvery", 3))
LONG_BREAK       = max(1, _cfg.get("longBreakMin", 5)) * 60
PRE_WARNING      = max(0, _cfg.get("preWarningSec", 10))
IDLE_SKIP        = 5 * 60

PAUSE_FILE = os.path.expanduser("~/.break_enforcer_pause")
LOG = "[break-enforcer]"

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
    ("SQUATS",          "20 bodyweight squats. Slow and controlled."),
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

# === Skip detection ===
def is_camera_in_use():
    """True only when camera is *actively* streaming.

    macOS launches a dedicated assistant process while the camera is in use
    and tears it down when released. Checking for that process is far more
    reliable than scanning lsof, which lists frameworks merely linked by
    browsers or video apps.
    """
    procs = ('AppleCameraAssistant', 'VDCAssistant', 'appleh13camerad')
    for p in procs:
        try:
            r = subprocess.run(['pgrep', '-x', p], capture_output=True, timeout=2)
            if r.returncode == 0:
                return True
        except Exception:
            continue
    return False


def is_keynote_presenting():
    try:
        if subprocess.run(['pgrep', '-x', 'Keynote'],
                          capture_output=True, timeout=2).returncode != 0:
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
        if subprocess.run(['pgrep', '-x', 'Microsoft PowerPoint'],
                          capture_output=True, timeout=2).returncode != 0:
            return False
        out = subprocess.run(
            ['osascript', '-e',
             'tell application "Microsoft PowerPoint" to return slide show window of active presentation is not missing value'],
            capture_output=True, text=True, timeout=3
        ).stdout
        return 'true' in out.lower()
    except Exception:
        return False


def is_zoom_in_meeting():
    try:
        if subprocess.run(['pgrep', '-f', 'zoom.us'],
                          capture_output=True, timeout=2).returncode != 0:
            return False
        out = subprocess.run(
            ['osascript', '-e',
             'tell application "System Events" to (exists (window 1 of process "zoom.us" whose name contains "Zoom Meeting"))'],
            capture_output=True, text=True, timeout=3
        ).stdout
        return 'true' in out.lower()
    except Exception:
        return False


def is_dnd_active():
    """Best effort: check macOS Focus / Do Not Disturb state."""
    try:
        path = os.path.expanduser("~/Library/DoNotDisturb/DB/Assertions.json")
        if os.path.exists(path) and os.path.getsize(path) > 60:
            with open(path) as f:
                content = f.read()
            return '"storeAssertionRecords"' in content and len(content) > 200
    except Exception:
        pass
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
    if paused:                   return f"paused ({info})"
    if is_camera_in_use():       return "camera in use (call/recording)"
    if is_zoom_in_meeting():     return "Zoom meeting active"
    if is_keynote_presenting():  return "Keynote presenting"
    if is_powerpoint_presenting():return "PowerPoint presenting"
    if is_dnd_active():          return "Do Not Disturb on"
    idle = get_idle_seconds()
    if idle > IDLE_SKIP:         return f"already idle {int(idle//60)} min"
    return None


# === Feedback ===
def play_sound(name="Glass"):
    subprocess.Popen(['afplay', f'/System/Library/Sounds/{name}.aiff'],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def speak(text):
    subprocess.Popen(['say', '-v', 'Samantha', text],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def notify(msg, title="Break Enforcer"):
    subprocess.Popen(
        ['osascript', '-e',
         f'display notification "{msg}" with title "{title}" sound name "Tink"'],
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
    headline, tip = random.choice(SHORT_PROMPTS)
    show_break(10, f"TEST · {headline}", tip)
    print("Test complete.")


def handle_sigint(signum, frame):
    print("\nBreak enforcer stopped. Take care of those eyes.")
    sys.exit(0)


def run():
    signal.signal(signal.SIGINT, handle_sigint)

    print("=" * 64)
    print("  20-20-20 Break Enforcer")
    print(f"  Short break every {WORK_INTERVAL//60} min for {SHORT_BREAK}s")
    print(f"  Long break every {LONG_BREAK_EVERY * WORK_INTERVAL//60} min for {LONG_BREAK//60} min")
    print("  Auto-skips: meetings, Keynote/PPT, camera, DND, idle")
    print("  Pause:  python3 break_enforcer.py pause 30")
    print("  Resume: python3 break_enforcer.py resume")
    print("  Stop:   Ctrl+C   (or: pkill -f break_enforcer.py)")
    print("=" * 64)

    break_count = 0
    while True:
        next_break = time.time() + WORK_INTERVAL
        _write_state(next_break, break_count)

        time.sleep(WORK_INTERVAL - PRE_WARNING)

        skip = reason_to_skip()
        if skip:
            print(f"{LOG} {datetime.now().strftime('%H:%M')} skip pre-warn: {skip}")
            time.sleep(PRE_WARNING)
            continue

        notify(f"Break in {PRE_WARNING}s. Wrap up.")
        time.sleep(PRE_WARNING)

        skip = reason_to_skip()
        if skip:
            print(f"{LOG} {datetime.now().strftime('%H:%M')} skip break:    {skip}")
            continue

        break_count += 1
        _write_state(time.time() + WORK_INTERVAL, break_count)
        play_sound("Glass")
        is_long = (break_count % LONG_BREAK_EVERY == 0)

        if is_long:
            headline, tip = random.choice(LONG_PROMPTS)
            speak(f"Long break. {headline.lower()}.")
            show_break(LONG_BREAK, headline, tip)
        else:
            headline, tip = random.choice(SHORT_PROMPTS)
            speak("Look away.")
            show_break(SHORT_BREAK, headline, tip)


if __name__ == "__main__":
    if len(sys.argv) > 1:
        cmd = sys.argv[1]
        rest = sys.argv[2:]
        if   cmd == "pause":  cli_pause(rest)
        elif cmd == "resume": cli_resume()
        elif cmd == "status": cli_status()
        elif cmd == "test":   cli_test()
        else:
            print(f"Unknown: {cmd}")
            print("Usage: break_enforcer.py [pause [mins] | resume | status | test]")
            sys.exit(1)
    else:
        run()
