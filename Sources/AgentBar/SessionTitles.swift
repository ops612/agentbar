import Foundation

/// What a session is actually about, for the row's first line.
///
/// Claude writes no title of its own, but the transcript's first user message
/// reads as one. Transcript files are not named after the session id, so the
/// id has to be read out of each file — hence the cache: the index is rebuilt
/// only when a session appears that is not in it, and at most once every few
/// seconds.
final class TitleIndex {
    private var index: [String: String] = [:]
    private var builtAt = Date.distantPast
    private let root: URL
    private let rebuildInterval: TimeInterval = 15
    /// Newest transcripts only. A live session's file is always among them.
    private let fileLimit = 60
    private let titleLimit = 80

    init(home: URL) {
        root = home.appendingPathComponent(".claude/projects")
    }

    func title(sessionId: String) -> String {
        guard !sessionId.isEmpty else { return "" }
        if let known = index[sessionId] { return known }
        guard Date().timeIntervalSince(builtAt) > rebuildInterval else { return "" }
        rebuild()
        return index[sessionId] ?? ""
    }

    private func rebuild() {
        builtAt = Date()
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }

        var files: [(url: URL, modified: Date)] = []
        for dir in dirs {
            guard let entries = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }
            for entry in entries where entry.pathExtension == "jsonl" {
                let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                files.append((entry, modified))
            }
        }
        files.sort { $0.modified > $1.modified }

        var found: [String: String] = [:]
        for file in files.prefix(fileLimit) {
            guard let (sessionId, title) = read(file.url), !sessionId.isEmpty else { continue }
            if found[sessionId] == nil {
                found[sessionId] = title
            }
        }
        index = found
    }

    /// Reads the head of a transcript for its session id and opening prompt.
    private func read(_ url: URL) -> (String, String)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let chunk = try? handle.read(upToCount: 16 * 1024),
              let text = String(data: chunk, encoding: .utf8)
        else { return nil }

        var sessionId = ""
        var title = ""
        for line in text.split(separator: "\n").prefix(40) {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if sessionId.isEmpty, let id = json["sessionId"] as? String {
                sessionId = id
            }
            if title.isEmpty, let prompt = prompt(from: json) {
                title = prompt
            }
            if !sessionId.isEmpty, !title.isEmpty { break }
        }
        guard !title.isEmpty else { return nil }
        return (sessionId, title)
    }

    /// The opening prompt, either from the queued-input record or the first user turn.
    private func prompt(from json: [String: Any]) -> String? {
        if json["type"] as? String == "queue-operation",
           json["operation"] as? String == "enqueue",
           let content = json["content"] as? String {
            return condense(content)
        }
        guard json["type"] as? String == "user",
              let message = json["message"] as? [String: Any],
              message["role"] as? String == "user"
        else { return nil }
        if let content = message["content"] as? String {
            return condense(content)
        }
        // Content can also be an array of typed blocks; take the first text one.
        if let blocks = message["content"] as? [[String: Any]] {
            for block in blocks where block["type"] as? String == "text" {
                if let text = block["text"] as? String {
                    return condense(text)
                }
            }
        }
        return nil
    }

    private func condense(_ raw: String) -> String? {
        let flattened = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Skip command wrappers and pasted blobs — neither reads as a title.
        guard !flattened.isEmpty, !flattened.hasPrefix("<") else { return nil }
        // Cap the stored string but add no ellipsis of its own: the row
        // truncates for display, and two ellipses in one line reads as a bug.
        return String(flattened.prefix(titleLimit))
    }
}
