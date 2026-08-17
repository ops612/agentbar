import Foundation

/// Bring the session's terminal (or its host app) to the front.
/// VS Code / Cursor cannot select a specific integrated-terminal tab;
/// those just activate the app on the session folder.
enum SessionFocus {
    static func open(_ session: LiveSession) {
        DispatchQueue.global(qos: .userInitiated).async {
            focus(session)
        }
    }

    private static func focus(_ session: LiveSession) {
        let host = resolveHost(from: session.pid)
        switch host {
        case .terminal:
            if !selectTerminalTab(device: session.ttyDevice) {
                activate(appName: "Terminal", cwd: nil)
            }
        case .iterm:
            if !selectITermTab(device: session.ttyDevice) {
                activate(appName: "iTerm", cwd: nil)
            }
        case .app(let name, let passCwd):
            activate(appName: name, cwd: passCwd ? session.cwd : nil)
        case .unknown:
            if selectTerminalTab(device: session.ttyDevice) { return }
            if selectITermTab(device: session.ttyDevice) { return }
            if !session.cwd.isEmpty {
                activate(appName: nil, cwd: session.cwd)
            }
        }
    }

    private enum Host {
        case terminal
        case iterm
        /// `passCwd` opens the editor on the session folder. Claude Desktop treats a path
        /// argument as something to open, so it is activated bare.
        case app(String, passCwd: Bool)
        case unknown
    }

    private static func resolveHost(from pid: Int32) -> Host {
        var current = pid
        for _ in 0..<16 {
            guard current > 1, let info = process(current) else { break }
            if let host = host(fromCommand: info.command) { return host }
            if info.ppid == current { break }
            current = info.ppid
        }
        return .unknown
    }

    private static func host(fromCommand command: String) -> Host? {
        if command.contains("Visual Studio Code.app") { return .app("Visual Studio Code", passCwd: true) }
        if command.contains("Code - Insiders.app") { return .app("Code - Insiders", passCwd: true) }
        if command.contains("Cursor.app") { return .app("Cursor", passCwd: true) }
        if command.contains("Windsurf.app") { return .app("Windsurf", passCwd: true) }
        if command.contains("Zed.app") { return .app("Zed", passCwd: true) }
        if command.contains("Warp.app") { return .app("Warp", passCwd: true) }
        if command.contains("Ghostty.app") { return .app("Ghostty", passCwd: true) }
        // Desktop-app sessions have no tty; activate the app rather than opening cwd in Finder.
        if command.contains("/Claude.app") { return .app("Claude", passCwd: false) }
        if command.contains("iTerm2.app") || command.contains("iTerm.app") { return .iterm }
        if command.contains("Terminal.app") { return .terminal }
        return nil
    }

    private static func process(_ pid: Int32) -> (ppid: Int32, command: String)? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-o", "ppid=,command=", "-p", String(pid)]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        let parts = text.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        guard parts.count >= 1, let ppid = Int32(parts[0]) else { return nil }
        let command = parts.count == 2 ? String(parts[1]) : ""
        return (ppid, command)
    }

    private static func selectTerminalTab(device: String) -> Bool {
        guard let needle = ttyNeedle(device) else { return false }
        let script = """
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    if (tty of t as text) contains "\(quote(needle))" then
                        set frontmost of w to true
                        set selected of t to true
                        return
                    end if
                end repeat
            end repeat
        end tell
        """
        return runAppleScript(script)
    }

    private static func selectITermTab(device: String) -> Bool {
        guard let needle = ttyNeedle(device) else { return false }
        let script = """
        tell application "iTerm"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if (tty of s as text) contains "\(quote(needle))" then
                            select w
                            select t
                            select s
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
        return runAppleScript(script)
    }

    private static func activate(appName: String?, cwd: String?) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        var args: [String] = []
        if let appName {
            args += ["-a", appName]
        }
        if let cwd, !cwd.isEmpty {
            args.append(cwd)
        }
        guard !args.isEmpty else { return }
        proc.arguments = args
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
    }

    private static func ttyNeedle(_ device: String) -> String? {
        let trimmed = device.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "??" || trimmed == Mapping.noTTY { return nil }
        return trimmed
    }

    private static func quote(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func runAppleScript(_ source: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", source]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do { try proc.run() } catch { return false }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }
}
