# Inpute

A lightweight background app that counts your own keystrokes and mouse
clicks per day, and shows the history as a six-month calendar heatmap.
For internal company use.

**Privacy:** Inpute only ever increments two integer counters (keys,
clicks). It never records *which* key was pressed, any character or text
content, window titles, cursor position, or anything else — and it never
sends anything over the network. See `Functional Spec.md` for the full
spec this was built against.

Built on [vercel-labs/native](https://github.com/vercel-labs/native)
(the `native` CLI, Zig-based). No WebView, no npm runtime dependency for
the app itself.

---

## Status

| Platform | Status |
|---|---|
| macOS | Built and verified — tray, calendar, autostart, permissions all working. |
| Windows | Implemented against the standard Win32 hook/registry APIs, but **not yet built or run on a real Windows machine**. Please report back once you've tried it. |
| Linux | Implemented (XRecord + evdev fallback), cross-compiles cleanly, but **not yet built or run on a real Linux machine**. Please report back once you've tried it. |

If something doesn't work on Windows or Linux, that's expected until
someone runs it there for the first time — open an issue with the build
output.

---

## Install / Build — macOS

1. Install the `native` CLI (needs Node.js):
   ```sh
   npm install -g @native-sdk/cli
   ```
2. Clone this repo and build:
   ```sh
   git clone <this repo's URL>
   cd Inpute
   node scripts/link-native-sdk.js
   native build
   ```
   The `link-native-sdk.js` step is required on **every fresh clone**,
   on every machine: `native eject` bakes a path into `build.zig.zon`
   pointing at wherever `npm` installed the CLI on the machine that ran
   it, which is never correct on a different computer. This script
   recomputes it for whatever machine you're on. If you ever see `no
   module named 'native_sdk' available`, re-run this script.
3. Package it into a real `.app` (this repo isn't set up with a paid
   Apple Developer signing identity, so this uses ad-hoc signing —
   fine for internal use):
   ```sh
   native package --target macos --signing adhoc
   mv zig-out/package/inpute.app /Applications/Inpute.app
   ```
4. **First launch**: since it's ad-hoc signed (not notarized by Apple),
   macOS Gatekeeper will refuse a plain double-click the first time.
   Right-click `Inpute.app` in `/Applications` → **Open** → confirm in
   the dialog. After that, it opens normally.
5. On first launch it needs two permissions — macOS will prompt, or
   grant them manually:
   **System Settings → Privacy & Security → Accessibility** and
   **System Settings → Privacy & Security → Input Monitoring** — enable
   Inpute in both. Until both are granted, the tray shows a
   "permission needed" state with menu items that jump straight to the
   right Settings pane.
6. To have it start automatically at login, open the tray menu (the
   `Keys · Clicks` item in the menu bar) → **Enable Start at Login**.

**Note on re-signing:** every time you rebuild and re-package, ad-hoc
signing produces a *different* signature, which means macOS will ask
you to re-grant Accessibility/Input Monitoring again after an update.
This is a real limitation of ad-hoc signing (see `Functional Spec.md`
§7.1) — if this becomes annoying, ask about setting up a proper company
Developer ID certificate so permissions persist across updates.

---

## Install / Build — Windows

1. Install the `native` CLI (needs Node.js):
   ```sh
   npm install -g @native-sdk/cli
   ```
2. Clone this repo and build:
   ```sh
   git clone <this repo's URL>
   cd Inpute
   node scripts/link-native-sdk.js
   native build
   ```
   The `link-native-sdk.js` step is required on **every fresh clone**,
   on every machine: `native eject` bakes a path into `build.zig.zon`
   pointing at wherever `npm` installed the CLI on the machine that ran
   it, which is never correct on a different computer. This script
   recomputes it for whatever machine you're on. If you ever see `no
   module named 'native_sdk' available`, re-run this script.
   This produces `zig-out\bin\inpute.exe`.
3. **First launch**: since the binary isn't code-signed, Windows
   SmartScreen will show "Windows protected your PC" the first time you
   run it. Click **More info → Run anyway**.
4. **Antivirus/EDR note**: Inpute installs low-level keyboard/mouse
   hooks to count events, which is also a classic keylogger signature.
   Some antivirus or EDR software may flag or quarantine the binary
   heuristically even though nothing malicious is happening. If your
   AV blocks it, you (or IT) may need to allow-list it.
5. No OS permission prompt is needed for the hooks themselves — it
   should just start counting.
6. To start automatically at login: tray menu → **Enable Start at
   Login** (writes a per-user Registry `Run` entry, no admin rights
   needed).

---

## Install / Build — Linux

1. Install build dependencies (Ubuntu/Debian example — package names
   may differ by distro, and GTK4 + the WebKitGTK 6.0 binding are
   fairly recent, so older LTS releases may need a newer repo):
   ```sh
   sudo apt install libgtk-4-dev libwebkitgtk-6.0-dev libx11-dev libxtst-dev
   ```
2. Install the `native` CLI (needs Node.js):
   ```sh
   npm install -g @native-sdk/cli
   ```
3. Clone this repo and build:
   ```sh
   git clone <this repo's URL>
   cd Inpute
   node scripts/link-native-sdk.js
   native build
   ```
   The `link-native-sdk.js` step is required on **every fresh clone**,
   on every machine: `native eject` bakes a path into `build.zig.zon`
   pointing at wherever `npm` installed the CLI on the machine that ran
   it, which is never correct on a different computer. This script
   recomputes it for whatever machine you're on. If you ever see `no
   module named 'native_sdk' available`, re-run this script.
   This produces `zig-out/bin/inpute`.
4. Just run it: `./zig-out/bin/inpute`.
5. **Input capture backend**: Inpute picks automatically based on your
   session:
   - **X11 with the `RECORD` extension** (most X11 setups): works with
     no special permission.
   - **Wayland, or X11 without `RECORD`**: falls back to reading
     `/dev/input/event*` directly, which needs your user in the
     `input` group:
     ```sh
     sudo usermod -aG input $USER
     ```
     then **log out and back in** for it to take effect. Until then,
     the tray will show a "permission needed" message with this exact
     instruction.
6. To start automatically at login: tray menu → **Enable Start at
   Login** (writes an XDG autostart `.desktop` file to
   `~/.config/autostart/`).

---

## Data & storage

One JSON file per day (just two integers — keystrokes, clicks) in:

| Platform | Location |
|---|---|
| macOS | `~/Library/Application Support/InputTracker/` |
| Linux | `$XDG_DATA_HOME/InputTracker/` (or `~/.local/share/InputTracker/`) |
| Windows | `%LOCALAPPDATA%\InputTracker\Data\` |

Deleting that folder wipes all history. Nothing is ever sent anywhere.

---

## Development

Run `node scripts/link-native-sdk.js` once after cloning (see above) —
every command below assumes it's already been run.

```sh
native dev     # build and run with hot reload (edits to src/app.native apply live)
native test    # run the test suite
native build   # produce a ReleaseFast binary in zig-out/bin/
native check   # validate src/*.native markup and app.zon
```

The build is "ejected" (`build.zig`/`build.zig.zon` are owned by this
repo, not regenerated by the CLI) — see `build.zig` for the
platform-specific framework/library linking (ApplicationServices/IOKit
on macOS, advapi32 on Windows, X11/Xtst on Linux).

Source layout:
- `src/main.zig` — `Model`/`Msg`/`update`, tray, calendar view, window wiring
- `src/app.native` — the main screen's markup
- `src/storage.zig` — per-day JSON load/save
- `src/date.zig` — calendar date math
- `src/platform/input.zig` — cross-platform facade; picks the OS backend
- `src/platform/{macos,windows,linux}_input.zig` — per-OS global input capture
- `src/platform/{macos,windows,linux}_autostart.zig` — per-OS "start at login"
