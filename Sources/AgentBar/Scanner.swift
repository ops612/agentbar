import Darwin
import Foundation

struct Scanner {
    let home: URL
    let claudeSessionsDir: URL
    let claudeStatusDir: URL
    private let titles: TitleIndex
    let grokRosterFile: URL
    let grokStatusDir: URL
    let codexStatusDir: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        self.claudeSessionsDir = home.appendingPathComponent(".claude/sessions")
        self.claudeStatusDir = home.appendingPathComponent(".claude/session-status")
        self.titles = TitleIndex(home: home)
        self.grokRosterFile = home.appendingPathComponent(".grok/active_sessions.json")
        self.grokStatusDir = home.appendingPathComponent(".grok/session-status")
        self.codexStatusDir = home.appendingPathComponent(".codex/session-status")
    }

    func scan() -> [LiveSession] {
        let claudeCandidates = readClaudeCandidates()
        let grokCandidates = readGrokCandidates()
        let codexCandidates = readCodexCandidates()
        let pids = Array(Set(
            claudeCandidates.map(\.pid) + grokCandidates.map(\.pid) + codexCandidates.map(\.pid)
        ))
        let procs = ProcessTable.lookup(pids: pids)

        var sessions: [LiveSession] = []

        for candidate in claudeCandidates {
            guard let proc = procs[candidate.pid] else { continue }
            guard Mapping.isInteractiveClaude(comm: proc.comm, args: proc.args) else { continue }
            sessions.append(
                LiveSession(
                    tool: .claude,
                    pid: candidate.pid,
                    sessionId: candidate.sessionId,
                    cwd: candidate.cwd,
                    tty: Mapping.normalizeTTY(proc.tty),
                    ttyDevice: proc.tty,
                    status: Mapping.claudeStatus(candidate.status),
                    folder: Mapping.folderLabel(cwd: candidate.cwd, home: home.path),
                    name: candidate.name,
                    title: titles.title(sessionId: candidate.sessionId)
                )
            )
        }

        for candidate in grokCandidates {
            guard let proc = procs[candidate.pid] else { continue }
            guard Mapping.isInteractiveGrok(comm: proc.comm, args: proc.args) else { continue }
            sessions.append(
                LiveSession(
                    tool: .grok,
                    pid: candidate.pid,
                    sessionId: candidate.sessionId,
                    cwd: candidate.cwd,
                    tty: Mapping.normalizeTTY(proc.tty),
                    ttyDevice: proc.tty,
                    status: Mapping.grokStatus(
                        sidecar: candidate.sidecarStatus,
                        sessionId: candidate.sessionId,
                        sidecarSessionId: candidate.sidecarSessionId,
                        events: candidate.eventsStatus
                    ),
                    folder: Mapping.folderLabel(cwd: candidate.cwd, home: home.path)
                )
            )
        }

        for candidate in codexCandidates {
            guard let proc = procs[candidate.pid] else { continue }
            guard Mapping.isInteractiveCodex(comm: proc.comm, args: proc.args) else { continue }
            sessions.append(
                LiveSession(
                    tool: .codex,
                    pid: candidate.pid,
                    sessionId: candidate.sessionId,
                    cwd: candidate.cwd,
                    tty: Mapping.normalizeTTY(proc.tty),
                    ttyDevice: proc.tty,
                    status: Mapping.codexStatus(
                        sidecar: candidate.status,
                        sessionId: candidate.sessionId,
                        sidecarSessionId: candidate.sessionId
                    ),
                    folder: Mapping.folderLabel(cwd: candidate.cwd, home: home.path)
                )
            )
        }

        return sessions.sorted()
    }

    private func readClaudeCandidates() -> [ClaudeCandidate] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: claudeSessionsDir,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else {
            return []
        }
        var result: [ClaudeCandidate] = []
        for file in files where file.pathExtension == "json" {
            let stem = file.deletingPathExtension().lastPathComponent
            guard let pid = Int32(stem), pid > 0 else { continue }
            guard let json = readCappedObject(at: file) else { continue }
            if let kind = json["kind"] as? String, kind != "interactive" { continue }
            let cwd = json["cwd"] as? String ?? home.path
            let status = json["status"] as? String
            let sessionId = json["sessionId"] as? String ?? json["session_id"] as? String ?? ""
            let name = json["name"] as? String ?? ""
            // Desktop-app sessions omit `status`; the AgentBar hook supplies it.
            let resolved = status ?? sidecarStatus(pid: pid, sessionId: sessionId)
            result.append(
                ClaudeCandidate(pid: pid, sessionId: sessionId, cwd: cwd, status: resolved, name: name)
            )
        }
        return result
    }

    /// Status written by the AgentBar Claude hook. Ignored when the sidecar belongs to a
    /// different session that has since reused the pid.
    private func sidecarStatus(pid: Int32, sessionId: String) -> String? {
        let file = claudeStatusDir.appendingPathComponent("\(pid).json")
        guard let json = readCappedObject(at: file) else { return nil }
        if !sessionId.isEmpty,
           let sidecarSession = json["session_id"] as? String,
           sidecarSession != sessionId {
            return nil
        }
        return json["status"] as? String
    }

    private func readGrokCandidates() -> [GrokCandidate] {
        guard let rows = readCappedArray(at: grokRosterFile) else { return [] }
        var result: [GrokCandidate] = []
        for row in rows {
            guard let sessionId = row["session_id"] as? String else { continue }
            let pidValue = row["pid"]
            let pid: Int32
            if let n = pidValue as? Int { pid = Int32(n) }
            else if let n = pidValue as? Int64 { pid = Int32(n) }
            else if let n = pidValue as? Double { pid = Int32(n) }
            else { continue }
            guard pid > 0 else { continue }
            let cwd = row["cwd"] as? String ?? home.path
            let sidecarURL = grokStatusDir.appendingPathComponent("\(pid).json")
            var sidecarStatus: String?
            var sidecarSessionId: String?
            if let sidecar = readCappedObject(at: sidecarURL) {
                sidecarStatus = sidecar["status"] as? String
                sidecarSessionId = sidecar["session_id"] as? String
            }
            let openedAt = parseISO8601(row["opened_at"] as? String)
            let eventsStatus = readGrokEventsStatus(
                cwd: cwd,
                sessionId: sessionId,
                openedAt: openedAt
            )
            result.append(
                GrokCandidate(
                    pid: pid,
                    sessionId: sessionId,
                    cwd: cwd,
                    sidecarStatus: sidecarStatus,
                    sidecarSessionId: sidecarSessionId,
                    eventsStatus: eventsStatus
                )
            )
        }
        return result
    }

    private func readCodexCandidates() -> [CodexCandidate] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: codexStatusDir,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else {
            return []
        }
        var result: [CodexCandidate] = []
        for file in files where file.pathExtension == "json" {
            let stem = file.deletingPathExtension().lastPathComponent
            guard let pid = Int32(stem), pid > 0 else { continue }
            guard let json = readCappedObject(at: file) else { continue }
            let cwd = json["cwd"] as? String ?? home.path
            let status = json["status"] as? String
            let sessionId = json["session_id"] as? String ?? json["sessionId"] as? String ?? ""
            result.append(CodexCandidate(pid: pid, sessionId: sessionId, cwd: cwd, status: status))
        }
        return result
    }

    /// Skip FIFOs, directories, and symlinks; refuse files larger than 64 KiB.
    private func readCappedData(at url: URL, maxBytes: Int = 65_536) -> Data? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true
        else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: maxBytes + 1)
        guard data.count <= maxBytes else { return nil }
        return data
    }

    private func readCappedObject(at url: URL) -> [String: Any]? {
        guard let data = readCappedData(at: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func readCappedArray(at url: URL) -> [[String: Any]]? {
        guard let data = readCappedData(at: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    }

    /// Last turn/phase after this process opened. Resume reuses events.jsonl
    /// from the previous process; ignoring older lines avoids a dead mid-turn
    /// looking live after `/resume`.
    private func readGrokEventsStatus(cwd: String, sessionId: String, openedAt: Date?) -> SessionStatus? {
        let encoded = Mapping.percentEncodePath(cwd)
        let url = home
            .appendingPathComponent(".grok/sessions", isDirectory: true)
            .appendingPathComponent(encoded, isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("events.jsonl")
        guard let text = readFileTail(at: url) else { return nil }
        var last: SessionStatus?
        // AskUserQuestion auto-allows, then sits in tool_execution until the
        // user answers. That stretch is waiting, not running.
        var blockedOnUser = false
        for line in text.split(whereSeparator: \.isNewline) {
            let raw = String(line)
            guard !raw.isEmpty,
                  let data = raw.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String
            else { continue }
            if let openedAt {
                guard let ts = parseISO8601(json["ts"] as? String), ts >= openedAt else { continue }
            }
            let toolName = json["tool_name"] as? String
            if type == "tool_started", Mapping.isUserBlockingTool(toolName) {
                blockedOnUser = true
            } else if type == "tool_completed", Mapping.isUserBlockingTool(toolName) {
                blockedOnUser = false
            } else if type == "turn_ended" {
                blockedOnUser = false
            }
            if let status = Mapping.grokEventStatus(type: type, phase: json["phase"] as? String, toolName: toolName) {
                last = (blockedOnUser && status == .running) ? .waiting : status
            }
        }
        return last
    }

    private func readFileTail(at url: URL, maxBytes: Int = 16_384) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true
        else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        let tail = min(UInt64(maxBytes), size)
        handle.seek(toFileOffset: size - tail)
        let data = handle.readDataToEndOfFile()
        guard var text = String(data: data, encoding: .utf8) else { return nil }
        if size > tail, let nl = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: nl)...])
        }
        return text
    }

    private func parseISO8601(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let date = Self.isoFractional.date(from: raw) { return date }
        return Self.isoBasic.date(from: raw)
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoBasic: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

private struct ClaudeCandidate {
    let pid: Int32
    let sessionId: String
    let cwd: String
    let status: String?
    /// Claude's own session name. The only thing separating desktop sessions,
    /// which share a cwd and have no tty.
    let name: String
}

private struct GrokCandidate {
    let pid: Int32
    let sessionId: String
    let cwd: String
    let sidecarStatus: String?
    let sidecarSessionId: String?
    let eventsStatus: SessionStatus?
}

private struct CodexCandidate {
    let pid: Int32
    let sessionId: String
    let cwd: String
    let status: String?
}

struct ProcInfo {
    let pid: Int32
    let tty: String
    let comm: String
    let args: String
}

enum ProcessTable {
    static func lookup(pids: [Int32]) -> [Int32: ProcInfo] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.map(String.init).joined(separator: ",")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        // No `comm=`: ps pads it to a fixed 16-char column, so an executable under a
        // path with a space (~/Library/Application Support/...) both truncates and
        // steals whitespace-split fields from args. proc_pidpath gives the real path.
        proc.arguments = ["-o", "pid=,tty=,args=", "-p", list]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return [:]
        }
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        var result: [Int32: ProcInfo] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let raw = String(line).trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { continue }
            let parts = raw.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard parts.count >= 2, let pid = Int32(parts[0]) else { continue }
            let tty = String(parts[1])
            // args keeps its spaces — only pid and tty are split off the front.
            let args = parts.count == 3 ? String(parts[2]) : ""
            let path = executablePath(pid: pid)
            let comm = path.isEmpty ? String(args.split(whereSeparator: \.isWhitespace).first ?? "") : path
            result[pid] = ProcInfo(pid: pid, tty: tty, comm: comm, args: args.isEmpty ? comm : args)
        }
        return result
    }

    /// Full executable path for a pid, spaces intact. Empty when the process is gone
    /// or owned by another user.
    private static func executablePath(pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        let written = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard written > 0 else { return "" }
        return String(cString: buffer)
    }
}
