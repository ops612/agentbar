import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var store: StatusStore

    var body: some View {
        Text(store.headerTitle)
        if !store.waiting.isEmpty {
            Divider()
            Section("Needs you") {
                ForEach(store.waiting) { session in
                    sessionButton(session)
                }
            }
        }
        if !store.ready.isEmpty {
            Divider()
            Section("Just finished") {
                ForEach(store.ready) { session in
                    sessionButton(session)
                }
            }
        }
        if !store.running.isEmpty {
            Divider()
            Section("Running") {
                ForEach(store.running) { session in
                    sessionButton(session)
                }
            }
        }
        if !store.idle.isEmpty {
            Divider()
            Section("Idle") {
                ForEach(store.idle) { session in
                    sessionButton(session)
                }
            }
        }
        Divider()
        Toggle("Launch at Login", isOn: Binding(
            get: { store.launchAtLogin },
            set: { store.setLaunchAtLogin($0) }
        ))
        Text(AppVersion.label)
        Button("Quit AgentBar") {
            NSApp.terminate(nil)
        }
    }

    private func sessionButton(_ session: LiveSession) -> some View {
        Button(session.rowLabel) {
            store.dismissReady(session)
            SessionFocus.open(session)
        }
    }
}
