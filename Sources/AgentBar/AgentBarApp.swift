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
            MenuBarView(store: store)
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
        .menuBarExtraStyle(.menu)
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

@MainActor
final class StatusStore: ObservableObject {
    @Published private(set) var sessions: [LiveSession] = []
    @Published var launchAtLogin = false

    private let scanner = Scanner()
    private var timer: Timer?
    private var lastRaw: [String: SessionStatus] = [:]
    private var readyAt: [String: Date] = [:]
    private var dismissed: Set<String> = []

    var icon: AggregateIcon { AggregateIcon.from(sessions) }

    var headerTitle: String {
        if sessions.isEmpty { return "No sessions" }
        return sessions.count == 1 ? "1 session" : "\(sessions.count) sessions"
    }

    var waiting: [LiveSession] { sessions.filter { $0.displayStatus == .waiting }.sorted() }
    var ready: [LiveSession] { sessions.filter { $0.displayStatus == .ready }.sorted() }
    var running: [LiveSession] { sessions.filter { $0.displayStatus == .running }.sorted() }
    var idle: [LiveSession] { sessions.filter { $0.displayStatus == .idle }.sorted() }

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
        let defaults = UserDefaults.standard
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

    func dismissReady(_ session: LiveSession) {
        guard session.displayStatus == .ready else { return }
        dismissed.insert(session.id)
        readyAt.removeValue(forKey: session.id)
        refresh()
    }

    func refresh() {
        let scanned = scanner.scan()
        let now = Date()
        let live = Set(scanned.map(\.id))
        readyAt = readyAt.filter { live.contains($0.key) }
        dismissed = dismissed.intersection(live)

        for session in scanned {
            let previous = lastRaw[session.id]
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
    }
}
