# Input Tracker — Functional Specification (Native SDK, macOS / Windows / Linux)

## Summary

A lightweight native desktop app that runs quietly in the system tray and
counts a user's own keystrokes and mouse clicks per day, storing daily totals
locally and displaying them as a six-month activity heatmap. Built on
[vercel-labs/native](https://github.com/vercel-labs/native).

**Core privacy constraint (must hold on every platform):** the app counts
events. It never stores, transmits, or logs *which* key was pressed, any
character or text content, window titles, or any other content — only integer
counters that increment on each keystroke and each mouse click. There is no
code path anywhere in this app that persists a key code, scan code, or
character to disk, memory beyond the current event, or network.

---

## 1. What the app does

- Runs as a background tray/menu-bar app with no visible main window by default.
- Tracks two numbers per calendar day: total keystrokes, total clicks.
- Displays today's running totals directly in the tray (e.g. `Keys 4,821 · Clicks 312`).
- Persists one record per day to local disk so history survives restarts.
- On demand, opens a calendar view: the last six months, one cell per day,
  color-intensity mapped to that day's total activity, with an all-time
  summary.
- Starts automatically at login (opt-in, user-controlled) and keeps running
  in the background until the user quits it.
- Never sends any data off the device. No network calls of any kind.

---

## 2. Data model

```zig
const DayCounts = struct {
    date: [10]u8,       // "YYYY-MM-DD"
    keystrokes: u64,
    clicks: u64,
};

const Model = struct {
    today: [10]u8,
    counts: DayCounts,       // today's live counters
    calendar_open: bool,
};

const Msg = union(enum) {
    key_event,       // one physical key press
    click_event,     // one physical mouse click (button-down only)
    tick,            // periodic timer, see §5
    open_calendar,
    close_calendar,
    quit,
};
```

`update(model, msg)` only ever mutates counters and UI flags — it contains no
disk or OS-input code. All I/O happens through the effects layer (§5, §6),
keeping the update loop deterministic and testable via `native test` /
`native automate replay`.

---

## 3. Storage

One JSON file per day, in a platform-appropriate app-data directory:

```json
{"date": "2026-07-08", "keystrokes": 4821, "clicks": 312}
```

| Platform | Directory |
|---|---|
| macOS | `~/Library/Application Support/InputTracker/` |
| Linux | `$XDG_DATA_HOME/inputtracker/` (fallback `~/.local/share/inputtracker/`) |
| Windows | `%APPDATA%\InputTracker\` |

Required operations:
- `load(day) -> DayCounts` — returns a zeroed record if no file exists for that date.
- `save(day, counts)` — writes/overwrites the file for that date.
- `loadAll() -> map[date]DayCounts` — scans the directory for the calendar view only; must skip and ignore any file that fails to parse (one corrupt day should never break the whole calendar).

No database, no external services — flat JSON files are sufficient given the
tiny record size and single-user, single-device scope.

---

## 4. Counting rules

- **Keystrokes:** one increment per physical key-down event. Key-up events are ignored. Modifier keys (Shift, Ctrl, etc.) count the same as any other key — this is a raw activity counter, not a "meaningful input" counter.
- **Clicks:** one increment per physical mouse-button-down event (left, right, or middle all count). Button-up/release events are ignored so a single physical click is counted exactly once.
- Both counters are simple monotonic increments within a day; they reset to zero at the start of each new calendar day (local system time), never mid-day.
- Nothing about *which* key or button, cursor position, click target, or timing between events is recorded — only the running totals.

---

## 5. Timing and day rollover

- A recurring timer fires once every 60 seconds while the app is running.
- On each tick:
  1. Compare the current system date to the `today` field in `Model`.
  2. If the date has changed: persist the outgoing day's final counts, reset
     the in-memory counters to a fresh (or previously-saved, if relaunched)
     record for the new date, update `today`.
  3. Persist the current day's counts to disk (this happens every tick,
     rollover or not, so at most ~60 seconds of activity is ever unsaved).
- On quit: persist current counts synchronously before the process exits, so
  a normal quit never loses data.

---

## 6. Platform input capture

Each OS needs its own global listener that observes key-down and
mouse-button-down events system-wide (not just within the app's own window)
and turns each into a `key_event` or `click_event` message. Each listener:

- Runs on a dedicated background thread, never the UI thread.
- Increments a counter and immediately discards the event — no buffering of
  event details, ever.
- Never suppresses, modifies, or delays the underlying input — this is a
  passive observer, not a filter or remapper.
- Fails gracefully: if the required permission is missing, the app keeps
  running and the tray shows a clear "permission needed" state rather than
  crashing or silently under-counting forever.

**macOS:** system-wide event tap (Quartz `CGEventTapCreate`) listening for
key-down and mouse-button-down events. Requires the user to grant
Accessibility permission to the built app in
System Settings → Privacy & Security → Accessibility.

**Windows:** low-level keyboard and mouse hooks (`WH_KEYBOARD_LL`,
`WH_MOUSE_LL` via `SetWindowsHookEx`), each running its own message-pump
thread as required by the Windows hook API. No extra permission prompt, but
some antivirus/EDR software flags low-level global hooks — surface this in
user-facing docs so it isn't mistaken for malicious behavior.

**Linux:** detect the session type (`XDG_SESSION_TYPE`) at startup and pick
a backend:
- **X11 (primary path):** the `XRecord` extension, observing
  `KeyPress`/`ButtonPress` globally. Try this first — it needs no special
  group membership or root privileges beyond a normal X11 session.
- **X11 fallback (XRecord unavailable):** some distros ship X servers with
  the `XRecord` (a.k.a. `RECORD`) extension disabled or absent — check with
  `XQueryExtension` at startup rather than assuming it exists. If it's
  missing, fall back to the same libinput/evdev approach used for Wayland
  below (reading `/dev/input/event*` directly). This works under X11 too,
  since evdev sits below the display server; it just needs the permission
  described in §7.3 instead of an X11-specific one. Detect and pick this
  path automatically — no separate build or manual config should be needed
  for a colleague running plain X11 without `XRecord`.
- **Wayland:** no portable protocol-level global-hook API exists. Use the
  same libinput/evdev approach as the X11 fallback above.
- If neither `XRecord` nor evdev access is available (e.g. permission
  denied and the user declines to grant it), show an explicit tray message
  that global counting isn't available in this environment rather than
  failing silently or under-counting forever.

---

## 7. Permissions & OS gatekeeping

Every platform blocks a global input listener by default. An implementing
agent should request each of these explicitly, detect whether they've been
granted, and degrade gracefully (never crash) when they haven't.

### 7.1 macOS

Two separate permissions are required — Accessibility alone is **not**
sufficient on modern macOS:
- **Accessibility** — System Settings → Privacy & Security → Accessibility.
  Required for `CGEventTapCreate` to receive events at all.
- **Input Monitoring** — System Settings → Privacy & Security → Input
  Monitoring. Required since macOS 10.15 (Catalina) for any process
  observing raw keyboard/mouse events, independent of Accessibility.
- The app must check both at launch (e.g. via
  `IOHIDCheckAccess`/`AXIsProcessTrusted`-style checks) and, if either is
  missing, show a tray state that explains what's missing and deep-links to
  the correct Settings pane rather than just silently failing to count.
- **Gatekeeper/notarization:** an unsigned, unnotarized build will be
  blocked from launching at all on a clean macOS install ("app is damaged" /
  "cannot be opened" dialogs). This isn't a runtime permission but has the
  same practical effect — the release build should be code-signed and
  notarized before distribution, or documented with the manual
  right-click-Open bypass for local/dev builds.

### 7.2 Windows

- No OS permission dialog is required for `SetWindowsHookEx` with
  `WH_KEYBOARD_LL`/`WH_MOUSE_LL` — a standard user-level process can install
  these hooks.
- **Code signing / SmartScreen:** an unsigned `.exe` triggers a SmartScreen
  "Windows protected your PC" warning on first run. Sign the release binary
  with a code-signing certificate to avoid this for real distribution.
- **Antivirus/EDR false positives:** low-level global keyboard hooks are a
  classic keylogger signature, so some AV/EDR products may quarantine or
  flag the binary heuristically even though nothing malicious is happening.
  Document this plainly for end users (and for whoever manages the machine)
  so it isn't mistaken for actual malware — this is a known false-positive
  pattern for any legitimate global-hook app, not specific to this one.

### 7.3 Linux

- **X11 with `XRecord` available:** no special permission beyond a normal
  user X11 session.
- **evdev fallback (X11 without `XRecord`, or Wayland):** reading
  `/dev/input/event*` requires either:
  - the user's account to be a member of the `input` group
    (`sudo usermod -aG input $USER`, then a re-login for the group change to
    take effect), or
  - running with elevated privileges (not recommended as a default — prefer
    guiding the user to the group-membership fix above).
- The app should detect at startup whether it can actually open the evdev
  device nodes, and if not, surface a clear one-time tray message with the
  `usermod` instruction above rather than failing silently or repeatedly
  retrying without explanation.

### 7.4 All platforms

- **Filesystem access:** the app creates its own data directory (§3) under
  the current user's standard app-data location. This doesn't require an OS
  permission prompt on any of the three platforms, but the app should handle
  and surface directory-creation failures (e.g. read-only home directory,
  disk full) instead of failing silently.

---

## 8. Tray / menu-bar UI

- A persistent tray icon/status item showing today's live totals, e.g.
  `Keys {keystrokes} · Clicks {clicks}`, updating automatically as the bound
  `Model` values change (no manual refresh logic required).
- A menu with at least:
  - **View Calendar** — opens the calendar window (§9).
  - **Quit** — flushes current counts to disk, then exits.
- Optional but recommended: a **Pause tracking** toggle that stops
  incrementing counters (listener keeps running but events are dropped)
  without quitting the app, and reflects the paused state visibly in the tray
  so it's never ambiguous whether tracking is active.

---

## 9. Calendar view

A separate native window, opened on demand (not shown at launch):

- **Range:** the six calendar months ending with the current month.
- **Data source:** read once from disk (`loadAll`) when the window opens —
  the calendar reflects saved history, not live in-memory counters, so it
  stays correct even across app restarts.
- **Grid:** standard Monday-first week rows per month, with empty padding
  cells for days outside the month.
- **Heat color:** each day cell's background is linearly interpolated
  between a dark base color and an accent color, proportional to
  `(keystrokes + clicks)` for that day relative to the busiest recorded day.
  Days with no record use the plain background color.
- **Today** gets a distinct visual highlight (e.g. outline/border) so it's
  easy to find at a glance.
- **Summary:** all-time total keystrokes and clicks shown above the grid.
- Hovering a day shows its exact counts (native tooltip or styled hover element).

---

## 10. Packaging and autostart

`native build` produces a single release binary per platform. Autostart at
login is a user-controlled, opt-in setting (never installed silently):

| Platform | Mechanism |
|---|---|
| macOS | `launchd` LaunchAgent (`~/Library/LaunchAgents/`) pointing at the built binary |
| Windows | Startup-folder shortcut or a per-user Registry `Run` entry pointing at the built `.exe` |
| Linux | XDG autostart `.desktop` file in `~/.config/autostart/` |

The settings/menu should expose a toggle to enable/disable this, and it
should be clear from the UI whether autostart is currently on.

---

## 11. Explicit scope boundaries

- **In scope:** a single-user, single-device, local-only activity counter
  with a local calendar visualization.
- **Out of scope:** capturing key identities/characters, window or
  application titles, clipboard contents, screenshots, or any other content
  beyond the two integer counters described above; any network transmission;
  any multi-user aggregation, central reporting, or remote configuration.
- Any future extension toward shared/team use is a distinct feature with its
  own consent, visibility, and data-ownership requirements, and is not
  covered by this spec.

---

## 12. Suggested implementation order for agents

1. Scaffold the app shell (`Model`/`Msg`/`update`) with hardcoded counts;
   confirm tray rendering and hot reload work.
2. Implement storage (`load`/`save`/`loadAll`) against real files; verify a
   hand-edited JSON file is read correctly.
3. Implement input capture for one platform first, behind a small
   interface/abstraction so the other two platforms plug in without changing
   `main.zig`. Include the permission-check/request flow from §7 for that
   platform from the start, not as an afterthought.
4. Add the 60-second tick effect, day-rollover logic, and quit-flush.
5. Build the calendar window (grid, heat color, summary stats).
6. Add the remaining two platforms' input-capture backends, each with its
   own §7 permission handling and graceful-degradation messaging.
7. Add pause/resume and autostart settings.
8. Package per platform (code-signing/notarization per §7.1/§7.2 for
   release builds).
