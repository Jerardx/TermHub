import Foundation

/// Fires each session's `restartSchedule` (daily at a time / every N hours).
///
/// A 30-second timer compares "next fire" dates against now; firing goes
/// through `TerminalController.restart`, so a scheduled restart behaves exactly
/// like pressing the Restart button (and starts sessions that aren't running).
/// Interval schedules are anchored to the session's last (re)start — a manual
/// restart resets the countdown via `noteStarted`.
@MainActor
final class RestartScheduler: ObservableObject {
    private weak var appState: AppState?
    private weak var controller: TerminalController?
    private var timer: Timer?

    /// Next planned fire per session, tagged with the schedule it was computed
    /// from so edits invalidate it on the next tick.
    private struct Entry {
        var schedule: RestartSchedule
        var date: Date
    }
    private var entries: [UUID: Entry] = [:]

    func attach(appState: AppState, controller: TerminalController) {
        self.appState = appState
        self.controller = controller
        controller.scheduler = self
        guard timer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = 5
        timer = t
    }

    /// Re-anchor an interval schedule when its session (re)starts, so "every
    /// N hours" counts from the latest start rather than a stale anchor.
    func noteStarted(_ id: UUID) {
        guard let session = appState?.session(id: id),
              let schedule = session.restartSchedule,
              case .every = schedule else { return }
        entries[id] = Entry(schedule: schedule, date: next(after: Date(), schedule: schedule))
    }

    private func tick() {
        guard let appState, let controller else { return }
        let now = Date()
        let live = Set(appState.allSessions.map(\.id))
        entries = entries.filter { live.contains($0.key) }
        for session in appState.allSessions {
            guard let schedule = session.restartSchedule else {
                entries[session.id] = nil
                continue
            }
            if let entry = entries[session.id], entry.schedule == schedule {
                if now >= entry.date {
                    controller.restart(session.id)
                    entries[session.id] = Entry(schedule: schedule, date: next(after: now, schedule: schedule))
                }
            } else {
                // New or edited schedule: (re)compute without firing.
                entries[session.id] = Entry(schedule: schedule, date: next(after: now, schedule: schedule))
            }
        }
    }

    private func next(after date: Date, schedule: RestartSchedule) -> Date {
        switch schedule {
        case .daily(let hour, let minute):
            return Calendar.current.nextDate(
                after: date,
                matching: DateComponents(hour: hour, minute: minute),
                matchingPolicy: .nextTime
            ) ?? date.addingTimeInterval(86_400)
        case .every(let hours):
            return date.addingTimeInterval(TimeInterval(hours) * 3600)
        }
    }
}
