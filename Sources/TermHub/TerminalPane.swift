import SwiftUI
import AppKit

// MARK: - Status color

extension SessionState {
    var indicatorColor: Color {
        switch self {
        case .notStarted: return .gray
        case .running: return .green
        case .exited(let code): return code == 0 ? .secondary : .red
        }
    }
}

// MARK: - Terminal pane (mounts a controller-owned terminal view)

struct TerminalPaneView: NSViewRepresentable {
    @ObservedObject var controller: TerminalController
    let sessionID: UUID
    let isFocused: Bool

    func makeNSView(context: Context) -> NSView {
        let wrapper = NSView()
        mount(into: wrapper)
        return wrapper
    }

    func updateNSView(_ wrapper: NSView, context: Context) {
        mount(into: wrapper)
    }

    private func mount(into wrapper: NSView) {
        _ = controller.revision // depend on revision so restarts remount the new view
        guard let term = controller.view(for: sessionID) else { return }
        if term.superview !== wrapper {
            term.removeFromSuperview()
            term.frame = wrapper.bounds
            term.autoresizingMask = [.width, .height]
            wrapper.addSubview(term)
        }
        if isFocused {
            DispatchQueue.main.async { wrapper.window?.makeFirstResponder(term) }
        }
    }
}

/// A single pane in the detail area: optional header chrome + terminal.
struct PaneView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var controller: TerminalController
    let id: UUID
    let showChrome: Bool

    var body: some View {
        let session = appState.session(id: id)
        let focused = appState.selectedSessionID == id
        VStack(spacing: 0) {
            if showChrome {
                HStack(spacing: 6) {
                    Circle()
                        .fill(session?.state.indicatorColor ?? .gray)
                        .frame(width: 7, height: 7)
                    Text(session?.title ?? "—").font(.caption).lineLimit(1)
                    Spacer()
                    Button { appState.closePane(id) } label: {
                        Image(systemName: "xmark").font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .help("Close pane")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(focused ? Color.accentColor.opacity(0.18) : Color(nsColor: .windowBackgroundColor))
                .contentShape(Rectangle())
                .onTapGesture { appState.selectedSessionID = id }
                Divider()
            }
            TerminalPaneView(controller: controller, sessionID: id, isFocused: focused)
                .overlay(alignment: .trailing) {
                    ScrollBar(controller: controller, id: id)
                }
        }
        .overlay(
            Rectangle()
                .strokeBorder(focused && showChrome ? Color.accentColor : .clear, lineWidth: 2)
        )
    }
}

/// Thin position indicator shown on the right edge of a terminal while it is
/// scrolled up into history; auto-hides at the bottom. Polls the live view's
/// `scrollPosition` (it isn't a published value).
struct ScrollBar: View {
    let controller: TerminalController
    let id: UUID

    @State private var position: Double = 1
    @State private var canScroll = false
    @State private var locked = false
    private let ticker = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            let visible = canScroll && position < 0.999
            let track = geo.size.height
            let knob = max(28, track * 0.12)
            let y = (track - knob) * position
            RoundedRectangle(cornerRadius: 3)
                .fill(locked ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.55))
                .frame(width: 5, height: knob)
                .padding(.trailing, 2)
                .offset(y: y)
                .opacity(visible ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: visible)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .help(locked ? "Output paused — scroll to bottom to resume" : "")
        }
        .allowsHitTesting(false)
        .onReceive(ticker) { _ in
            if let info = controller.scrollInfo(for: id) {
                position = info.position
                canScroll = info.canScroll
                locked = info.locked
            }
        }
    }
}
