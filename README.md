# TermHub

A native **macOS terminal session manager**. A sidebar lists terminal sessions
organised into collapsible groups; the detail area shows one or more live
terminals (split view) you can work in. Built for running and monitoring many
processes (dev servers, logs, ssh, builds, AI agents) from a single window.

<p align="center">
  <a href="https://github.com/Jerardx/TermHub/releases/latest/download/TermHub.dmg">
    <img src="https://img.shields.io/badge/⬇%20Download-TermHub.dmg-2ea44f?style=for-the-badge&logo=apple&logoColor=white" alt="Download TermHub.dmg">
  </a>
  &nbsp;
  <a href="https://github.com/Jerardx/TermHub/releases/latest">
    <img src="https://img.shields.io/github/v/release/Jerardx/TermHub?style=for-the-badge&label=Latest&color=blue" alt="Latest release">
  </a>
</p>

> The app is **ad-hoc signed**, not notarized. On first launch right-click the
> app → **Open** (or allow it in **System Settings → Privacy & Security**).

## Features

- **Groups & sessions** — full CRUD, drag-and-drop reordering, move sessions
  between groups
- **Split view** — up to 4 live terminals side by side; sessions stay alive in
  the background across any layout change
- **Status at a glance** — running / exited-0 / failed indicator, unread-output
  dot, a live-activity pulse while output streams
- **Per-session mute** — silence the unread dot and the activity pulse for noisy
  sessions (persisted)
- **Working scroll** — mouse wheel scrolls our 10k-line scrollback, with
  scroll-lock (output parks while you read history) and a scroll-position
  indicator; fullscreen TUIs (e.g. Claude Code, vim, htop) get the wheel
  forwarded so they scroll their own viewport — just like iTerm/Terminal.app.
  Keyboard scroll too (Scroll menu: ⇧PageUp/Down, ⌥⌘↑/↓, ⇧⌘↑/↓)
- **Per-session output log** — raw pty mirror on disk, recoverable even after a
  full-screen TUI (context-menu: *Open Session Log* / *Reveal Log in Finder*)
- **Broadcast input** — type one command and send it to many sessions at once
- **Profiles / templates** — capture a group or the whole workspace and relaunch
  it with one click
- **Auto-run command** per session, restart / stop, exit notifications
- **Keyboard navigation** — ⌘1–9, ⌘[ / ⌘] between sessions; global ⌘⌥T show/hide
- Child shells are terminated on quit (no orphaned ptys)

## Install

1. [**Download TermHub.dmg**](https://github.com/Jerardx/TermHub/releases/latest/download/TermHub.dmg)
2. Open the DMG and drag **TermHub** into **Applications**
3. First launch: right-click **TermHub → Open** (it's ad-hoc signed, not
   notarized, so Gatekeeper asks once)

## Build from source

Only the **Command Line Tools** are required — there is no Xcode project, and
`xcodebuild` is intentionally not used.

```bash
swift build                 # compile
swift run TermHub           # run for development (no .app bundle)

./scripts/make-app.sh release   # assemble + ad-hoc sign build/TermHub.app
./scripts/make-dmg.sh           # build build/TermHub.dmg
```

## Tech stack

- **Swift + SwiftUI** (app shell, sidebar, sheets)
- **[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)** for the terminal
  emulator / pty
- **Swift Package Manager** — no Xcode project (Command Line Tools only)

See [`CLAUDE.md`](CLAUDE.md) for architecture notes and the source layout.
