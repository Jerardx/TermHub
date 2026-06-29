import SwiftUI
import AppKit
import Combine

// MARK: - ANSI / control-sequence cleaning

/// Turns a raw pty byte stream into readable plain text: strips ANSI escape
/// sequences (CSI / OSC / charset designators) and resolves carriage-return,
/// backspace and tab overwrites onto a per-line buffer. Good for line-based
/// output (shells, dev servers, ssh, bun logs); full-screen TUIs that paint via
/// cursor addressing still won't reconstruct perfectly, but stay readable
/// instead of becoming escape-code soup.
enum AnsiCleaner {
    static func clean(_ data: Data) -> String {
        let scalars = Array(String(decoding: data, as: UTF8.self).unicodeScalars)
        let n = scalars.count
        var lines: [[Character]] = []
        var line: [Character] = []
        var col = 0

        func put(_ ch: Character) {
            if col < line.count {
                line[col] = ch
            } else {
                while line.count < col { line.append(" ") }
                line.append(ch)
            }
            col += 1
        }
        func newline() { lines.append(line); line = []; col = 0 }

        var i = 0
        while i < n {
            let s = scalars[i]
            switch s {
            case "\u{1B}": // ESC — start of an escape sequence
                i += 1
                guard i < n else { break }
                let next = scalars[i]
                if next == "[" { // CSI: ESC [ … final byte 0x40–0x7E
                    i += 1
                    while i < n {
                        let v = scalars[i].value
                        if v >= 0x40 && v <= 0x7E { break }
                        i += 1
                    }
                } else if next == "]" { // OSC: ESC ] … (BEL or ESC \)
                    i += 1
                    while i < n {
                        if scalars[i] == "\u{07}" { break }
                        if scalars[i] == "\u{1B}", i + 1 < n, scalars[i + 1] == "\\" { i += 1; break }
                        i += 1
                    }
                } else if next == "(" || next == ")" || next == "#" {
                    i += 1 // charset designator: skip the following byte too
                }
                // else: ESC + single char (e.g. ESC =, ESC >) — already consumed
            case "\r":
                col = 0
            case "\n":
                newline()
            case "\u{08}": // backspace
                if col > 0 { col -= 1 }
            case "\t":
                let stop = ((col / 8) + 1) * 8
                while col < stop { put(" ") }
            case "\u{07}": // bell — ignore
                break
            default:
                if s.value >= 0x20 { put(Character(s)) }
            }
            i += 1
        }
        if !line.isEmpty { lines.append(line) }
        return lines.map { String($0) }.joined(separator: "\n")
    }
}

// MARK: - Native scrollable text view

/// An NSTextView in an NSScrollView — fast, native scrolling for large logs.
struct LogTextView: NSViewRepresentable {
    let text: String
    let tail: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.isSelectable = true
            tv.isRichText = false
            tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            tv.textContainerInset = NSSize(width: 6, height: 6)
            tv.backgroundColor = .textBackgroundColor
            tv.autoresizingMask = [.width]
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView, tv.string != text else { return }
        tv.string = text
        if tail { tv.scrollToEndOfDocument(nil) }
    }
}

// MARK: - Log viewer sheet

/// Browse every session's captured output log, with scroll + live tailing.
struct LogViewerSheet: View {
    @EnvironmentObject var appState: AppState
    var controller: TerminalController
    @Environment(\.dismiss) private var dismiss

    @State private var selectedID: UUID?
    @State private var content = ""
    @State private var autoRefresh = true
    @State private var tail = true

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "doc.text.magnifyingglass")
                Text("Session Logs").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()

            HSplitView {
                List(selection: $selectedID) {
                    ForEach(appState.groups) { group in
                        Section(group.name) {
                            ForEach(group.sessions) { session in
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(session.state.indicatorColor)
                                        .frame(width: 7, height: 7)
                                    Text(session.title).lineLimit(1)
                                    Spacer()
                                    if !logExists(session.id) {
                                        Image(systemName: "minus.circle")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .help("No log yet")
                                    }
                                }
                                .tag(session.id)
                            }
                        }
                    }
                }
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)

                VStack(spacing: 0) {
                    if content.isEmpty {
                        ContentUnavailableView(
                            "No Log Output",
                            systemImage: "doc.text",
                            description: Text("This session hasn't produced output yet, or hasn't been started since logging was enabled.")
                        )
                    } else {
                        LogTextView(text: content, tail: tail)
                    }
                    Divider()
                    HStack(spacing: 12) {
                        Toggle("Auto-refresh", isOn: $autoRefresh)
                        Toggle("Tail", isOn: $tail)
                        Spacer()
                        Button("Refresh") { reload() }
                        Button("Reveal in Finder") { reveal() }
                            .disabled(selectedID == nil)
                    }
                    .toggleStyle(.checkbox)
                    .padding(8)
                }
                .frame(minWidth: 420)
            }
        }
        .frame(minWidth: 780, minHeight: 500)
        .onAppear {
            if selectedID == nil {
                selectedID = appState.selectedSessionID ?? appState.allSessions.first?.id
            }
            reload()
        }
        .onChange(of: selectedID) { _, _ in reload() }
        .onReceive(ticker) { _ in if autoRefresh { reload() } }
    }

    private func logExists(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: controller.logURL(for: id).path)
    }

    private func reload() {
        guard let id = selectedID,
              let data = try? Data(contentsOf: controller.logURL(for: id)) else {
            content = ""
            return
        }
        // Cap to the last ~2 MB so huge logs stay responsive.
        let capped = data.count > 2_000_000 ? Data(data.suffix(2_000_000)) : data
        content = AnsiCleaner.clean(capped)
    }

    private func reveal() {
        guard let id = selectedID else { return }
        NSWorkspace.shared.activateFileViewerSelecting([controller.logURL(for: id)])
    }
}
