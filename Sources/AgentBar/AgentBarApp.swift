import AppKit
import SwiftUI

enum AppVersion {
    static var label: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "AgentBar \(short) (\(build))"
    }
}

@main
struct AgentBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = StatusStore()
    @StateObject private var pulse = PulseClock()

    var body: some Scene {
        MenuBarExtra {
            PanelView(store: store)
        } label: {
            let icon = store.icon
            let phase = icon.pulses ? pulse.phase : 1
            Image(nsImage: IconRenderer.image(icon: icon, pulse: phase))
                .id("\(icon.kind)-\(icon.waiting)-\(icon.ready)-\(icon.running)-\(Int((phase * 8).rounded()))")
                .onAppear { pulse.setActive(icon.pulses) }
                .onChange(of: icon.pulses) { _, pulses in
                    pulse.setActive(pulses)
                }
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class PulseClock: ObservableObject {
    @Published private(set) var phase: CGFloat = 1
    private var timer: Timer?

    func setActive(_ active: Bool) {
        if active {
            guard timer == nil else { return }
            timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    let t = Date.timeIntervalSinceReferenceDate
                    self?.phase = CGFloat((sin(t * 2 * .pi / 1.2) + 1) / 2)
                }
            }
            if let timer {
                RunLoop.main.add(timer, forMode: .common)
            }
        } else if timer != nil {
            timer?.invalidate()
            timer = nil
            if phase != 1 { phase = 1 }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

struct SessionGroup: Identifiable {
    let id: String
    let title: String
    let sessions: [LiveSession]
}

@MainActor
final class StatusStore: ObservableObject {
    @Published private(set) var sessions: [LiveSession] = []
    @Published var launchAtLogin = false
    /// Free-text filter over folder, tool and handle. Empty shows everything.
    @Published var query = ""
    @Published var chimeOnWaiting = false

    private let scanner = Scanner()
    private var timer: Timer?
    private var lastRaw: [String: SessionStatus] = [:]
    private var readyAt: [String: Date] = [:]
    private var dismissed: Set<String> = []
    /// When each session last changed state, for the age shown on its row.
    private var changedAt: [String: Date] = [:]
    private var loaded = false

    private let chimeKey = "agentbar.chimeOnWaiting"

    var icon: AggregateIcon { AggregateIcon.from(sessions) }

    var headerTitle: String {
        if sessions.isEmpty { return "No sessions" }
        return sessions.count == 1 ? "1 session" : "\(sessions.count) sessions"
    }

    /// Counts for the header chips. Idle is omitted — it is the resting state,
    /// and the list below already shows it.
    var headerCounts: [(SessionStatus, Int)] {
        [SessionStatus.waiting, .ready, .running]
            .map { status in (status, sessions.filter { $0.displayStatus == status }.count) }
            .filter { $0.1 > 0 }
    }

    var matches: [LiveSession] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return sessions }
        return sessions.filter { session in
            session.folder.lowercased().contains(trimmed)
                || session.handle.lowercased().contains(trimmed)
                || session.tool.displayName.lowercased().contains(trimmed)
                || session.cwd.lowercased().contains(trimmed)
        }
    }

    var groups: [SessionGroup] {
        let shown = matches
        return [
            SessionGroup(
                id: "waiting",
                title: "Needs you",
                sessions: shown.filter { $0.displayStatus == .waiting }.sorted()
            ),
            SessionGroup(
                id: "ready",
                title: "Just finished",
                sessions: shown.filter { $0.displayStatus == .ready }.sorted()
            ),
            SessionGroup(
                id: "running",
                title: "Running",
                sessions: shown.filter { $0.displayStatus == .running }.sorted()
            ),
            SessionGroup(
                id: "idle",
                title: "Idle",
                sessions: shown.filter { $0.displayStatus == .idle }.sorted()
            )
        ].filter { !$0.sessions.isEmpty }
    }

    init() {
        let defaults = UserDefaults.standard
        chimeOnWaiting = defaults.bool(forKey: chimeKey)
        refresh()
        loaded = true
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
        let decidedKey = "agentbar.loginItemDecided"
        do {
            if !defaults.bool(forKey: decidedKey) {
                if !LoginItem.isEnabled {
                    try LoginItem.setEnabled(true)
                }
                defaults.set(true, forKey: decidedKey)
            }
            launchAtLogin = LoginItem.isEnabled
        } catch {
            // Leave the flag unset so a later ~/Applications launch can still first-register.
            launchAtLogin = LoginItem.isEnabled
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
            UserDefaults.standard.set(true, forKey: "agentbar.loginItemDecided")
            launchAtLogin = LoginItem.isEnabled
        } catch {
            launchAtLogin = LoginItem.isEnabled
        }
    }

    func setChimeOnWaiting(_ enabled: Bool) {
        chimeOnWaiting = enabled
        UserDefaults.standard.set(enabled, forKey: chimeKey)
    }

    /// How long this session has held its current state.
    func age(_ session: LiveSession) -> String? {
        guard let at = changedAt[session.id] else { return nil }
        return Mapping.shortAge(at)
    }

    func dismissReady(_ session: LiveSession) {
        guard session.displayStatus == .ready else { return }
        dismissed.insert(session.id)
        readyAt.removeValue(forKey: session.id)
        refresh()
    }

    func focus(_ session: LiveSession) {
        dismissReady(session)
        SessionFocus.open(session)
    }

    func revealInFinder(_ session: LiveSession) {
        guard !session.cwd.isEmpty else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.cwd)
    }

    func copyPath(_ session: LiveSession) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.cwd, forType: .string)
    }

    func refresh() {
        let scanned = scanner.scan()
        let now = Date()
        let live = Set(scanned.map(\.id))
        readyAt = readyAt.filter { live.contains($0.key) }
        dismissed = dismissed.intersection(live)
        changedAt = changedAt.filter { live.contains($0.key) }

        var startedWaiting = false
        for session in scanned {
            let previous = lastRaw[session.id]
            if previous != session.status {
                changedAt[session.id] = now
                if loaded, session.status == .waiting { startedWaiting = true }
            }
            if session.status == .idle {
                if previous == .running || previous == .waiting {
                    readyAt[session.id] = now
                    dismissed.remove(session.id)
                }
            } else {
                readyAt.removeValue(forKey: session.id)
                dismissed.remove(session.id)
            }
        }
        for (id, at) in readyAt where now.timeIntervalSince(at) >= Mapping.readyWindow {
            readyAt.removeValue(forKey: id)
        }
        lastRaw = Dictionary(uniqueKeysWithValues: scanned.map { ($0.id, $0.status) })

        let decorated = scanned.map { session -> LiveSession in
            guard session.status == .idle,
                  !dismissed.contains(session.id),
                  let at = readyAt[session.id]
            else { return session }
            var copy = session
            copy.readySince = at
            return copy
        }
        if decorated != sessions {
            sessions = decorated
        }
        if startedWaiting, chimeOnWaiting {
            NSSound(named: "Ping")?.play()
        }
    }
}
