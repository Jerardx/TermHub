# TermHub

A native macOS terminal **session manager**. A sidebar lists terminal sessions
organised into collapsible groups; the detail area shows one or more live
terminals (split view) you can work in. Built for running and monitoring many
processes (dev servers, logs, ssh, builds) from a single window.

## Tech stack

- **Swift + SwiftUI** (app shell, sidebar, sheets)
- **SwiftTerm** (`LocalProcessTerminalView`) for the terminal emulator / pty
- **Swift Package Manager** — no Xcode project (only Command Line Tools are
  required; `xcodebuild` is intentionally not used)
- Swift **language mode v5** (set in `Package.swift`) to avoid Swift 6 strict
  concurrency friction in the AppKit/SwiftUI bridge

## Build & run

```bash
swift build                       # compile
swift run TermHub                 # run for development (no .app bundle)

./scripts/trim-icon.swift icon.png icon-trimmed.png  # trim checkerboard/shadow, add squircle alpha
./scripts/make-icon.sh icon-trimmed.png  # regenerate Resources/AppIcon.icns from the trimmed PNG
./scripts/make-app.sh release     # assemble + ad-hoc sign build/TermHub.app
./scripts/make-dmg.sh             # build build/TermHub.dmg (app + /Applications symlink)
```

The app is **ad-hoc signed**, not notarized — fine for local install (no
quarantine when built locally), but other Macs would hit Gatekeeper.

## Source layout (`Sources/TermHub/`)

- `TermHubApp.swift` — `@main` App, `AppDelegate` (activation policy, notification
  auth, global hotkey), and `SessionCommands` (⌘1–9, ⌘[ / ⌘] navigation menu)
- `Models.swift` — `TerminalSession`, `SessionGroup`, `SessionState`,
  `SessionTemplate`/`GroupTemplate`/`Profile`, and `AppState` (the
  `@MainActor ObservableObject` that owns everything + persistence)
- `TerminalController.swift` — owns the live `SessionTerminalView`s and *vends*
  them to panes; manages pty lifecycle, restart/stop, exit handling
- `ContentView.swift` — `NavigationSplitView`, sidebar (DnD + context menus),
  split-pane layout (`PaneView` / `TerminalPaneView`), new/edit session sheets
- `ProfilesView.swift` — profile manager + editor sheets
- `LogViewerView.swift` — in-app log browser (`LogViewerSheet`), native
  scrollable `LogTextView`, and `AnsiCleaner` (strips ANSI / resolves CR-BS-tab
  overwrites) for readable history of any session's captured output
- `Notifications.swift` — `Notifier`, safe wrapper around `UNUserNotificationCenter`
- `HotKeyManager.swift` — global ⌘⌥T toggle via the Carbon Hot Key API

## Architecture notes

- **Terminals stay alive across layout changes.** `TerminalController` keeps a
  `[UUID: SessionTerminalView]` and hands views to SwiftUI panes. A session's
  pty keeps running even when its view is not mounted, so background sessions
  survive switching/splitting.
- **Split view** is driven by `AppState.paneIDs` (1–4 panes shown left→right).
  `selectedSessionID` is the focused pane. `reconcilePanes` keeps them coherent.
- **Profiles** are `[GroupTemplate]` (each group with `[SessionTemplate]`), so a
  profile can capture one group *or* the whole workspace. Legacy flat-`templates`
  profiles auto-migrate when decoded.
- **Persistence:** groups → `~/Library/Application Support/TermHub/config.json`,
  profiles → `profiles.json`. Live state (running/exited/unread) is not persisted.
  Nested `@Published` changes are autosaved via Combine subscriptions
  (`rewireAutosave`).

## Features

Groups & sessions CRUD · status indicators (running / exited-0 / failed) ·
unread-output dot · live-activity pulse (status dot pulses while output is
streaming) · per-session mute (suppresses the unread dot and the activity pulse;
persisted) · auto-run command per session · restart/stop · ⌘1–9 & ⌘[/⌘]
navigation · keyboard scroll of the focused terminal (Scroll menu: ⇧PageUp/Down,
⌥⌘↑/↓ line, ⇧⌘↑/↓ top/bottom — reliable when a repainting TUI snaps the wheel to
the bottom) · global ⌘⌥T show/hide · exit notifications · 10k-line scrollback +
per-session output log (raw pty mirror, recoverable even after a full-screen TUI;
"Open Session Log" / "Reveal Log in Finder" in the context menu) · in-app log
viewer (toolbar 🔍 — scrollable, ANSI-cleaned, live-tailing browser of every
session's log; the way to read full history for alt-screen TUI agents) · child
shells terminated on app quit (no orphaned ptys) · profiles/templates (incl. "Save All
Groups as Profile") · split view (up to 4 panes) · drag-and-drop reordering and
moving sessions between groups.

## Conventions

- Keep new code matching the existing SwiftUI/AppKit style in these files.
- All UI state lives on `AppState` (`@MainActor`); mutate through its methods so
  persistence and pane reconciliation stay correct.
- Delegate callbacks from SwiftTerm are `nonisolated`; hop to `@MainActor` (see
  `processTerminated`) before touching `AppState`.
