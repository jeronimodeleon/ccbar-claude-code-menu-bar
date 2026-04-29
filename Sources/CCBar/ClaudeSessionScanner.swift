import Foundation

// One Claude Code session = one .jsonl transcript file under ~/.claude/projects/.
struct ClaudeSession: Hashable {
    let sessionId: String         // UUID from filename
    let projectPath: String       // authoritative cwd (read from JSONL)
    let projectName: String       // basename of projectPath
    let aiTitle: String?          // "ai-title" record (often absent)
    let lastPrompt: String?       // most recent "last-prompt" record
    let firstUserMessage: String? // first non-meta user prompt
    let filePath: String
    let creationDate: Date        // .jsonl birth time (≈ when claude started writing)
    let mtime: Date
    let lastEntryType: String?    // "user", "assistant", ...
    let lastStopReason: String?   // "end_turn", "tool_use", ...

    var idleSeconds: TimeInterval { -mtime.timeIntervalSinceNow }

    var isAwaitingInput: Bool {
        lastEntryType == "assistant"
            && lastStopReason == "end_turn"
            && idleSeconds > 3
    }

    var isWorking: Bool {
        idleSeconds < 3 || lastStopReason == "tool_use"
    }

    // Best human-readable label for the session, in fallback order.
    var displayTitle: String? {
        if let t = aiTitle?.trimmed, !t.isEmpty { return t }
        if let t = lastPrompt?.trimmed, !t.isEmpty { return t.truncated(to: 100) }
        if let t = firstUserMessage?.trimmed, !t.isEmpty { return t.truncated(to: 100) }
        return nil
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    func truncated(to n: Int) -> String { count <= n ? self : prefix(n) + "…" }
}

final class ClaudeSessionScanner {
    private let projectsDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
    private var cache: [String: (mtime: Date, session: ClaudeSession)] = [:]

    func scan() -> [ClaudeSession] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: projectsDir) else { return [] }

        var result: [ClaudeSession] = []
        for dirName in dirs {
            let dirPath = (projectsDir as NSString).appendingPathComponent(dirName)
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dirPath) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                let filePath = (dirPath as NSString).appendingPathComponent(file)
                if let session = parse(path: filePath) {
                    result.append(session)
                }
            }
        }
        return result
    }

    private func parse(path: String) -> ClaudeSession? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        guard let mtime = attrs?[.modificationDate] as? Date else { return nil }
        let creationDate = (attrs?[.creationDate] as? Date) ?? mtime
        if let cached = cache[path], cached.mtime == mtime { return cached.session }

        let sessionId = ((path as NSString).lastPathComponent as NSString).deletingPathExtension

        // Head of file: cwd + ai-title + first non-meta user message.
        let head = readBytes(path: path, atStart: true, bytes: 16_384) ?? ""
        let (cwd, aiTitle, firstUserMessage) = parseHead(head)

        // Tail of file: last-prompt + last entry state.
        let tail = readBytes(path: path, atStart: false, bytes: 16_384) ?? ""
        let (lastType, lastStop, lastPrompt) = parseTail(tail)

        // Without a cwd we can't match this session to a tab — skip it.
        guard let projectPath = cwd else { return nil }

        let session = ClaudeSession(
            sessionId: sessionId,
            projectPath: projectPath,
            projectName: (projectPath as NSString).lastPathComponent,
            aiTitle: aiTitle,
            lastPrompt: lastPrompt,
            firstUserMessage: firstUserMessage,
            filePath: path,
            creationDate: creationDate,
            mtime: mtime,
            lastEntryType: lastType,
            lastStopReason: lastStop
        )
        cache[path] = (mtime, session)
        return session
    }

    private func readBytes(path: String, atStart: Bool, bytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if atStart {
            try? handle.seek(toOffset: 0)
        } else {
            let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
            try? handle.seek(toOffset: start)
        }
        let data = (try? handle.read(upToCount: bytes)) ?? Data()
        return String(data: data, encoding: .utf8)
    }

    private func parseHead(_ text: String) -> (cwd: String?, aiTitle: String?, firstUser: String?) {
        var cwd: String?
        var aiTitle: String?
        var firstUser: String?

        for line in text.split(separator: "\n") {
            guard let bytes = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            else { continue }

            // Authoritative cwd from any record that has one.
            if cwd == nil, let c = obj["cwd"] as? String { cwd = c }

            let type = obj["type"] as? String

            if type == "ai-title", aiTitle == nil, let t = obj["aiTitle"] as? String {
                aiTitle = t
            }

            if firstUser == nil, type == "user", obj["isMeta"] as? Bool != true {
                if let text = userMessageText(obj), !text.isEmpty, !text.hasPrefix("<") {
                    firstUser = text
                }
            }

            if cwd != nil && aiTitle != nil && firstUser != nil { break }
        }
        return (cwd, aiTitle, firstUser)
    }

    private func parseTail(_ text: String) -> (type: String?, stopReason: String?, lastPrompt: String?) {
        var lastType: String?
        var lastStop: String?
        var lastPrompt: String?

        // Walk lines in reverse so the first hit is the most recent.
        for line in text.split(separator: "\n").reversed() where !line.isEmpty {
            guard let bytes = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            else { continue }
            let type = obj["type"] as? String

            if lastPrompt == nil, type == "last-prompt", let p = obj["lastPrompt"] as? String {
                lastPrompt = p
            }
            if lastType == nil {
                lastType = type
                lastStop = (obj["message"] as? [String: Any])?["stop_reason"] as? String
            }
            if lastType != nil && lastPrompt != nil { break }
        }
        return (lastType, lastStop, lastPrompt)
    }

    // user message content can be a string or an array of {type:text, text:...} blocks.
    private func userMessageText(_ obj: [String: Any]) -> String? {
        guard let m = obj["message"] as? [String: Any] else { return nil }
        if let s = m["content"] as? String { return s }
        if let arr = m["content"] as? [[String: Any]] {
            for part in arr where part["type"] as? String == "text" {
                if let t = part["text"] as? String { return t }
            }
        }
        return nil
    }
}
