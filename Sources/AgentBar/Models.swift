import AppKit
import Foundation

enum AgentTool: String, Equatable {
    case claude
    case grok
    case codex

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .grok: return "Grok"
        case .codex: return "Codex"
        }
    }
}

enum SessionStatus: String, Equatable {
    case running
    case idle
    case waiting
    /// Idle for less than `Mapping.readyWindow` after a turn finished.
    /// Parked idle chats stay `.idle`.
    case ready
}

struct LiveSession: Identifiable, Equatable, Comparable {
    // Grok's live roster can list two session_ids on one pid.
    // Claude files are one-per-pid; sessionId is empty when the JSON has none.
    var id: String {
        sessionId.isEmpty ? "\(tool.rawValue)-\(pid)" : "\(tool.rawValue)-\(pid)-\(sessionId)"
    }
    let tool: AgentTool
    let pid: Int32
    let sessionId: String
    let cwd: String
    let tty: String
    /// Raw `ps` TTY (`ttys007`), used to select a Terminal/iTerm tab.
    let ttyDevice: String
    let status: SessionStatus
    let folder: String
    /// Agent-side session name, when the tool publishes one. Empty for Grok and Codex.
    var name: String = ""
    /// Set when this session just flipped to idle. Nil once parked or dismissed.
    var readySince: Date? = nil

    var displayStatus: SessionStatus {
        if status == .idle, let readySince,
           Date().timeIntervalSince(readySince) < Mapping.readyWindow {
            return .ready
        }
        return status
    }

    var rowLabel: String {
        let word: String
        if displayStatus == .ready, let readySince {
            word = "ready · \(Mapping.shortAge(readySince))"
        } else {
            word = displayStatus.rawValue
        }
        return "\(tool.displayName)  \(folder)  ·  \(handle)  ·  \(word)"
    }

    /// The tty, or the session name when there is no tty (desktop-app sessions).
    var handle: String {
        if tty != Mapping.noTTY { return tty }
        return name.isEmpty ? tty : name
    }

    static func < (lhs: LiveSession, rhs: LiveSession) -> Bool {
        if lhs.folder != rhs.folder { return lhs.folder < rhs.folder }
        if lhs.handle != rhs.handle { return lhs.handle < rhs.handle }
        if lhs.tool.rawValue != rhs.tool.rawValue { return lhs.tool.rawValue < rhs.tool.rawValue }
        return lhs.sessionId < rhs.sessionId
    }
}

enum AggregateKind: Equatable {
    case empty
    case needsYou
    case ready
    case busy
    case allIdle
}

struct AggregateIcon: Equatable {
    let kind: AggregateKind
    /// Sessions blocked on the user. Blue digit; 0 is omitted.
    let waiting: Int
    /// Turns that just finished. Green digit; 0 is omitted.
    let ready: Int
    /// Sessions mid-turn. Red digit; 0 is omitted.
    let running: Int
    let hollow: Bool

    var nsColor: NSColor {
        switch kind {
        case .empty: return NSColor.secondaryLabelColor
        case .needsYou: return NSColor.systemBlue
        case .ready: return NSColor.systemGreen
        case .busy: return NSColor.systemRed
        case .allIdle: return NSColor.systemGreen
        }
    }

    var pulses: Bool { kind == .needsYou || kind == .ready }

    static func from(_ sessions: [LiveSession]) -> AggregateIcon {
        if sessions.isEmpty {
            return AggregateIcon(kind: .empty, waiting: 0, ready: 0, running: 0, hollow: true)
        }
        let waiting = sessions.filter { $0.displayStatus == .waiting }.count
        let ready = sessions.filter { $0.displayStatus == .ready }.count
        let running = sessions.filter { $0.displayStatus == .running }.count
        // Digits never swap meaning. Color is the most urgent of the three.
        if waiting > 0 {
            return AggregateIcon(kind: .needsYou, waiting: waiting, ready: ready, running: running, hollow: false)
        }
        if ready > 0 {
            return AggregateIcon(kind: .ready, waiting: 0, ready: ready, running: running, hollow: false)
        }
        if running > 0 {
            return AggregateIcon(kind: .busy, waiting: 0, ready: 0, running: running, hollow: false)
        }
        return AggregateIcon(kind: .allIdle, waiting: 0, ready: 0, running: 0, hollow: false)
    }
}

enum Mapping {
    /// How long a just-finished idle session stays "ready" before it is a parked chat.
    static let readyWindow: TimeInterval = 10 * 60

    static func shortAge(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h"
    }

    static func claudeStatus(_ raw: String?) -> SessionStatus {
        switch raw {
        case "waiting": return .waiting
        case "idle": return .idle
        case "busy", "shell": return .running
        default: return .running
        }
    }

    static func grokStatus(
        sidecar: String?,
        sessionId: String,
        sidecarSessionId: String?,
        events: SessionStatus?
    ) -> SessionStatus {
        let sidecarMatches = sidecarSessionId == sessionId
        // Hook Notification is the real permission UI. events.jsonl also
        // emits permission_prompt for auto-allowed tools, so sidecar wins.
        if sidecarMatches, sidecar == "waiting" { return .waiting }
        // Interrupted turns skip the Stop hook, so a stale "running" sidecar
        // must not beat a later turn_ended (including cancelled).
        if events == .idle { return .idle }
        // SessionStart (startup and resume) writes idle. Welcome text can
        // still emit turn_started; the sidecar is the idle signal there.
        if sidecarMatches, sidecar == "idle" { return .idle }
        if let events { return events }
        if sidecarMatches, sidecar == "running" { return .running }
        // Resume / brand-new session with no turn yet is sitting at a prompt.
        return .idle
    }

    static func isUserBlockingTool(_ name: String?) -> Bool {
        name == "ask_user_question"
    }

    static func grokEventStatus(type: String, phase: String?, toolName: String? = nil) -> SessionStatus? {
        if type == "tool_started", isUserBlockingTool(toolName) { return .waiting }
        switch type {
        case "turn_ended":
            return .idle
        case "turn_started":
            return .running
        case "phase_changed":
            switch phase {
            case "permission_prompt":
                return .waiting
            case "streaming_text", "streaming_reasoning", "tool_execution", "waiting_for_model":
                return .running
            default:
                return nil
            }
        default:
            return nil
        }
    }

    static func percentEncodePath(_ path: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }

    static func folderLabel(cwd: String, home: String) -> String {
        let cwdURL = URL(fileURLWithPath: cwd).standardizedFileURL
        let homeURL = URL(fileURLWithPath: home).standardizedFileURL
        if cwdURL.path == homeURL.path { return "~" }
        let name = cwdURL.lastPathComponent
        return name.isEmpty ? cwd : name
    }

    /// Shown in place of a tty for sessions that have none.
    static let noTTY = "—"

    static func normalizeTTY(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "??" { return noTTY }
        if trimmed.lowercased().hasPrefix("tty") {
            return String(trimmed.dropFirst(3))
        }
        return trimmed
    }

    static func isInteractiveClaude(comm: String, args: String) -> Bool {
        if args.contains("chrome-native-host") { return false }
        if args.contains("Claude.app") { return false }
        let commBase = URL(fileURLWithPath: comm).lastPathComponent
        if commBase == "claude" { return true }
        let first = args.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        return URL(fileURLWithPath: first).lastPathComponent == "claude"
    }

    static func isInteractiveGrok(comm: String, args: String) -> Bool {
        let commBase = URL(fileURLWithPath: comm).lastPathComponent
        if commBase == "grok" { return true }
        let first = args.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        return URL(fileURLWithPath: first).lastPathComponent == "grok"
    }

    static func isInteractiveCodex(comm: String, args: String) -> Bool {
        if args.contains("Codex.app") { return false }
        if args.contains("ChatGPT.app") { return false }
        let tokens = args.split(whereSeparator: \.isWhitespace).map { String($0) }
        let first = tokens.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        let commBase = URL(fileURLWithPath: comm).lastPathComponent
        guard commBase == "codex" || first == "codex" else { return false }
        // Non-interactive / helper invocations are not a tab to check.
        if tokens.dropFirst().contains("exec") { return false }
        if tokens.dropFirst().contains("mcp") { return false }
        return true
    }

    static func codexStatus(sidecar: String?, sessionId: String, sidecarSessionId: String?) -> SessionStatus {
        guard let sidecar, let sidecarSessionId, sidecarSessionId == sessionId else {
            return .running
        }
        switch sidecar {
        case "waiting": return .waiting
        case "idle": return .idle
        case "running": return .running
        default: return .running
        }
    }
}

enum IconRenderer {
    static func image(icon: AggregateIcon, pulse: CGFloat = 1) -> NSImage {
        let font = NSFont.menuBarFont(ofSize: 12)
        var badges: [(text: NSString, color: NSColor)] = []
        if icon.waiting > 0 { badges.append(("\(icon.waiting)" as NSString, .systemBlue)) }
        if icon.ready > 0 { badges.append(("\(icon.ready)" as NSString, .systemGreen)) }
        if icon.running > 0 { badges.append(("\(icon.running)" as NSString, .systemRed)) }

        var badgeLayout: [(text: NSString, attrs: [NSAttributedString.Key: Any], size: NSSize)] = []
        var width: CGFloat = 16
        for badge in badges {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: badge.color
            ]
            let size = badge.text.size(withAttributes: attrs)
            if badgeLayout.isEmpty {
                width = 15 + size.width + 2
            } else {
                width += 4 + size.width
            }
            badgeLayout.append((badge.text, attrs, size))
        }
        let imageSize = NSSize(width: width, height: 16)
        let image = NSImage(size: imageSize, flipped: false) { rect in
            let diameter: CGFloat = 10
            let circle = NSRect(
                x: 2,
                y: (rect.height - diameter) / 2,
                width: diameter,
                height: diameter
            )
            let alpha: CGFloat = icon.pulses ? (0.35 + 0.65 * pulse) : 1
            if icon.hollow {
                let path = NSBezierPath(ovalIn: circle.insetBy(dx: 1, dy: 1))
                path.lineWidth = 1.5
                icon.nsColor.withAlphaComponent(alpha).setStroke()
                path.stroke()
            } else {
                icon.nsColor.withAlphaComponent(alpha).setFill()
                NSBezierPath(ovalIn: circle).fill()
            }
            var x: CGFloat = 15
            for badge in badgeLayout {
                let y = (rect.height - badge.size.height) / 2 - 1
                badge.text.draw(at: NSPoint(x: x, y: y), withAttributes: badge.attrs)
                x += badge.size.width + 4
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
