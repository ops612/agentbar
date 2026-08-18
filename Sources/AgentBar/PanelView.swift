import AppKit
import SwiftUI

extension SessionStatus {
    var tint: Color {
        switch self {
        case .waiting: return .blue
        case .ready: return .green
        case .running: return .red
        case .idle: return .green
        }
    }

    /// Idle is the one state drawn hollow — present, but nothing to act on.
    var isHollow: Bool { self == .idle }
}

struct PanelView: View {
    @ObservedObject var store: StatusStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            body(for: store.groups)
            Divider()
            footer
        }
        .frame(width: 320)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(store.headerTitle)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                CountChips(counts: store.headerCounts)
            }
            if store.sessions.count > 3 || !store.query.isEmpty {
                SearchField(text: $store.query)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func body(for groups: [SessionGroup]) -> some View {
        if groups.isEmpty {
            Text(store.sessions.isEmpty ? "No agent sessions running." : "No sessions match “\(store.query)”.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(groups) { group in
                        Text(group.title.uppercased())
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                            .padding(.bottom, 2)
                        ForEach(group.sessions) { session in
                            SessionRow(session: session, age: store.age(session)) {
                                store.focus(session)
                            } reveal: {
                                store.revealInFinder(session)
                            } copyPath: {
                                store.copyPath(session)
                            }
                        }
                    }
                }
                .padding(.bottom, 6)
            }
            .frame(maxHeight: 320)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Launch at login", isOn: Binding(
                get: { store.launchAtLogin },
                set: { store.setLaunchAtLogin($0) }
            ))
            Toggle("Chime when a session needs you", isOn: Binding(
                get: { store.chimeOnWaiting },
                set: { store.setChimeOnWaiting($0) }
            ))
            HStack {
                Text(AppVersion.label)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Compact dot-and-number chips, same color vocabulary as the menu bar icon.
private struct CountChips: View {
    let counts: [(SessionStatus, Int)]

    var body: some View {
        HStack(spacing: 7) {
            ForEach(counts, id: \.0) { status, count in
                HStack(spacing: 3) {
                    StatusDot(status: status)
                    Text("\(count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }
}

private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            TextField("Filter by folder or tool", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
    }
}

private struct SessionRow: View {
    let session: LiveSession
    let age: String?
    let focus: () -> Void
    let reveal: () -> Void
    let copyPath: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: focus) {
            HStack(spacing: 8) {
                StatusDot(status: session.displayStatus)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.folder)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text("\(session.tool.displayName) · \(session.handle)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if let age {
                    Text(age)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(hovering ? .secondary : .tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { hovering = $0 }
        .help(session.cwd)
        .contextMenu {
            Button("Focus session", action: focus)
            Button("Reveal folder in Finder", action: reveal)
            Button("Copy folder path", action: copyPath)
        }
    }
}

struct StatusDot: View {
    let status: SessionStatus

    var body: some View {
        Group {
            if status.isHollow {
                Circle()
                    .strokeBorder(status.tint.opacity(0.7), lineWidth: 1.5)
            } else {
                Circle().fill(status.tint)
            }
        }
        .frame(width: 8, height: 8)
    }
}
