// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

/// The clipboard history as a floating panel, like Spotlight: it takes the
/// keyboard without bringing R2Drop forward, so after picking an entry the
/// app you were in is still in front and ⌘V pastes it there.
@MainActor
final class ClipboardPanelController: NSObject, NSWindowDelegate {
    static let shared = ClipboardPanelController()

    private var panel: NSPanel?

    func toggle() {
        if panel?.isVisible == true {
            close()
        } else {
            show()
        }
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // A fresh view each time, so it opens on an empty search at the top.
        let host = NSHostingView(rootView: ClipboardHistoryView { [weak self] in self?.close() })
        panel.contentView = host
        panel.setContentSize(host.fittingSize)

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2,
                                         y: visible.minY + visible.height * 0.62 - panel.frame.height / 2))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
        panel?.contentView = nil
    }

    /// Clicking anywhere else dismisses it.
    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    private func makePanel() -> NSPanel {
        let panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        return panel
    }
}

/// Borderless panels refuse to become key unless told otherwise, and the
/// search field needs the keyboard.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private enum HistoryFilter: String, CaseIterable {
    case all = "All"
    case text = "Text"
    case images = "Images"
    case uploads = "R2 Uploads"

    func includes(_ entry: ClipboardEntry) -> Bool {
        switch self {
        case .all: true
        case .text: entry.kind == .text
        case .images: entry.kind == .image
        case .uploads: entry.kind == .upload
        }
    }
}

private struct ClipboardHistoryView: View {
    let close: () -> Void
    @ObservedObject private var history = ClipboardHistory.shared
    @State private var query = ""
    @State private var filter = HistoryFilter.all
    @State private var selection: UUID?
    @FocusState private var isSearchFocused: Bool

    init(close: @escaping () -> Void) {
        self.close = close
    }

    private var results: [ClipboardEntry] {
        let words = query.lowercased().split(separator: " ")
        return history.entries.filter { entry in
            guard filter.includes(entry) else { return false }
            let haystack = [entry.text, entry.title, entry.sourceApp ?? "", entry.url ?? ""].joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    private var selected: ClipboardEntry? {
        results.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                TextField("Search clipboard history", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($isSearchFocused)
                    .onSubmit(copySelection)
                    .onKeyPress(.upArrow) { move(-1) }
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.escape) {
                        close()
                        return .handled
                    }
            }
            .padding(.horizontal, 18)
            .frame(height: 50)

            Picker("Show", selection: $filter) {
                ForEach(HistoryFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, Metrics.panelPadding)
            .padding(.bottom, 8)

            Divider()
            list
            Divider()
            footer
        }
        .frame(width: Metrics.panelWidth, height: 500)
        .glassSurface(in: RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous), fallback: .regularMaterial)
        .onAppear {
            isSearchFocused = true
            selection = results.first?.id
        }
        .onChange(of: query) { selection = results.first?.id }
        .onChange(of: filter) { selection = results.first?.id }
    }

    @ViewBuilder
    private var list: some View {
        if results.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: query.isEmpty ? "clipboard" : "magnifyingglass")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text(query.isEmpty ? "Nothing here yet. Copy something, or upload an image." : "No matches")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(results) { entry in
                            ClipboardRow(entry: entry, isSelected: entry.id == selection)
                                .id(entry.id)
                                .contentShape(Rectangle())
                                .onTapGesture { copy(entry) }
                                .onHover { if $0 { selection = entry.id } }
                        }
                    }
                    .padding(8)
                }
                .onChange(of: selection) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text(results.count == 1 ? "1 item" : "\(results.count) items")
            Spacer()
            Text("↩ Copy")
            Button("Delete ⌘⌫") {
                if let entry = selected {
                    _ = move(1)
                    history.delete(entry)
                }
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(selected == nil)
            Text("esc Close")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .frame(height: 34)
    }

    private func move(_ offset: Int) -> KeyPress.Result {
        let results = results
        guard !results.isEmpty else { return .handled }
        let index = results.firstIndex { $0.id == selection } ?? -1
        selection = results[min(max(index + offset, 0), results.count - 1)].id
        return .handled
    }

    private func copySelection() {
        if let entry = selected {
            copy(entry)
        }
    }

    private func copy(_ entry: ClipboardEntry) {
        history.copy(entry)
        close()
        HUD.shared.show(entry.kind == .upload ? "Copied link" : "Copied")
    }
}

private struct ClipboardRow: View {
    let entry: ClipboardEntry
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            preview
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.system(size: 13))
                    .lineLimit(entry.kind == .text ? 2 : 1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            isSelected ? Color.accentColor.opacity(0.2) : Color.clear,
            in: RoundedRectangle(cornerRadius: Metrics.cardRadius - 2, style: .continuous)
        )
    }

    private var detail: String {
        let when = entry.date.formatted(.relative(presentation: .named))
        switch entry.kind {
        case .upload:
            return "Uploaded to R2 · \(when)"
        case .files where entry.paths.count == 1:
            return [(entry.paths[0] as NSString).deletingLastPathComponent, when].joined(separator: " · ")
        default:
            return [entry.sourceApp, when].compactMap { $0 }.joined(separator: " · ")
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch entry.kind {
        case .image, .upload:
            ZStack(alignment: .bottomTrailing) {
                if let image = ClipboardHistory.thumbnail(entry) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    symbol("photo")
                }
                if entry.kind == .upload {
                    Image(systemName: "icloud.and.arrow.up.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(Color.orange, in: Circle())
                        .padding(2)
                }
            }
        case .files:
            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.paths.first ?? "/"))
                .resizable()
                .scaledToFit()
        case .text:
            symbol(URL(string: entry.text)?.scheme?.hasPrefix("http") == true ? "link" : "text.alignleft")
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .frame(width: 36, height: 36)
            .card(cornerRadius: 7)
    }
}
