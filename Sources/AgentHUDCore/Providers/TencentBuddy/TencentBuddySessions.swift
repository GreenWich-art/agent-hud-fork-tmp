import AgentHUDSupport
import Foundation

// CodeBuddy / WorkBuddy transcript fields, token layouts and request identities follow Tokscale tencent_buddy.rs (MIT).
enum TencentBuddySessions {
    static func read(_ url: URL, source: AdditionalSource) throws -> ProviderSessions {
        let folder = url.deletingLastPathComponent(), stem = url.deletingPathExtension().lastPathComponent
        // `<session>/subagents/*.jsonl` belong to their parent session.
        let parent = folder.lastPathComponent == "subagents" ? folder.deletingLastPathComponent().lastPathComponent : nil
        let client = source == .codebuddy ? "CodeBuddy Code" : source.vendor
        var sessions: [String: ProviderSession] = [:], events: [String: [String: ProviderEvent]] = [:], incomplete = false
        // Each session's models, read while its events are; WorkBuddy's credit attribution correlates them with the
        // per-model entries its own metering records. `reached` collects the models whose calls name one of the app's
        // own model entries (`custom-local:` routes), which marks them as reached over an API rather than built in.
        var models: [String: Set<String>] = [:], reached: Set<String> = []
        // The latest successful model and the newest 429 ceiling each session logged, again in pass order.
        var lastModels: [String: String] = [:], hits: [ProviderLimitHit] = []
        // The latest title of each kind the engine appended, by its rank in `titleFields`.
        var named: [String: [Int: String]] = [:]
        try ProviderFiles.lines(url) { json, line in
            let raw = parent ?? json["sessionId"].stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? stem
            let id = "\(source.rawValue):\(raw)", date = ProviderDate.milliseconds(json["timestamp"])
            var session = sessions[id] ?? ProviderSession(id: id, title: "\(source.vendor) · \(raw.prefix(8))", path: url.path, client: client)
            if session.workspace == nil, let cwd = json["cwd"].stringValue, !cwd.isEmpty {
                session.workspace = cwd
                session.title = URL(fileURLWithPath: cwd).lastPathComponent
            }
            if let date { session.startedAt = min(session.startedAt ?? date, date); session.lastActivity = max(session.lastActivity ?? date, date) }
            sessions[id] = session
            let kind = json["type"].stringValue, provider = json["providerData"]
            if parent == nil, let rank = titleFields.firstIndex(where: { $0.type == kind }),
               let title = SessionTitle.named(json[titleFields[rank].field].stringValue), !placeholderTitles.contains(title),
               !title.hasPrefix("<image_local_path>") {
                named[id, default: [:]][rank] = title
            }
            guard kind == "function_call" || (kind == "message" && json["role"].stringValue == "assistant"),
                  json["status"] == .null || json["status"].stringValue == "completed",
                  let usage = [json["message"]["usage"], provider["usage"], provider["rawUsage"]].first(where: { $0.objectValue != nil }) else {
                // A 429 answer carries no usage but names the ceiling it hit and when the vendor resets it; its session's
                // latest successful model is the one it interrupted.
                if let hit = limitHit(json, session: id, date: date, lastModels: lastModels) { hits.append(hit) }
                return
            }
            let counted: (input: Int, output: Int, cache: Int, write: Int, reasoning: Int)?
            do { counted = try self.tokens(usage) } catch { incomplete = true; return }
            guard let tokens = counted else { return }
            guard let date else { incomplete = true; return }
            // The models a session called, for credit attribution: every model whose calls the transcript priced.
            if let name = model(json) {
                models[id, default: []].insert(name)
                if nonEmpty(provider["requestModelId"])?.hasPrefix("custom-local:") == true { reached.insert(name) }
                lastModels[id] = name
            }
            // One response can be written on both its message and its function call line.
            let key = nonEmpty(provider["messageId"]).map { "message:\($0)" } ?? nonEmpty(provider["traceId"]).map { "trace:\($0)" }
                ?? nonEmpty(json["id"]).map { "\(raw):item:\($0)" } ?? "\(raw):\(stem):line-\(line)"
            let event = ProviderEvent(id: key, model: model(json) ?? "Unknown", timestamp: date, input: tokens.input, output: tokens.output,
                                      cacheRead: tokens.cache, cacheWrite: tokens.write, reasoning: tokens.reasoning)
            if let previous = events[id]?[key], previous.input + previous.output + previous.cacheRead > event.input + event.output + event.cacheRead { return }
            events[id, default: [:]][key] = event
        }
        return ProviderSessions(sessions: sessions.keys.sorted().compactMap { key in
            sessions[key].map { var item = $0
                if let title = named[key]?.min(by: { $0.key < $1.key })?.value { item.title = title }
                item.events = (events[key] ?? [:]).values.sorted { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) }; return item }
        }, notice: incomplete ? L10n.text("部分 \(source.vendor) 记录缺少时间或计数无法核对，未计入统计",
                                          "Some \(source.vendor) records lack a time or have inconsistent counts and were excluded") : nil,
                          models: models, apiReached: reached, limitHits: hits)
    }

    /// One 429 ceiling a line logged, nil for anything else: only an incomplete answer that carries a 429 error reports
    /// one. The message names the window in the vendor's words and the reset in the time zone the client logs (its own).
    /// The model is the session's latest successful one, because the failed call itself records none; a 429 before any
    /// success names nothing.
    static func limitHit(_ json: ProviderJSON, session: String, date: Date?, lastModels: [String: String]) -> ProviderLimitHit? {
        guard let date, json["status"].stringValue == "incomplete",
              providerErrorStatus(json["providerData"]["error"]) == 429,
              let message = nonEmpty(json["providerData"]["error"]["message"]),
              let window = ProviderLimitHit.windows.first(where: { message.contains(Self.phrases[$0]!) }),
              let model = lastModels[session],
              let reset = resetDate(message) else { return nil }
        return ProviderLimitHit(model: model, window: window, reset: reset, observedAt: date)
    }

    /// How the vendor's words name each window its 429s report. A window whose words are missing is never matched.
    static let phrases: [String: String] = ["5h": "5 小时", "day": "每日", "week": "每周", "month": "每月"]

    private static func providerErrorStatus(_ error: ProviderJSON) -> Int? {
        error["status"].numberValue.flatMap { $0 == $0.rounded() ? Int(exactly: $0) : nil }
            ?? error["status"].stringValue.flatMap(Int.init)
    }

    /// The reset time in the vendor's message, a wall-clock time in the client's own zone (`2026-10-14 01:06:03 重置`).
    private static func resetDate(_ message: String) -> Date? {
        guard let range = message.range(of: #"(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) 重置"#, options: .regularExpression) else { return nil }
        return DateParsing.localWallClock(String(message[range].dropLast(3)))
    }

    /// Title lines the engine appends to a session's transcript, in the order it prefers them: the name the user gave,
    /// the generated title, then the topic it tracks. The folder name stands in until one arrives.
    static let titleFields: [(type: String, field: String)] = [("custom-title", "customTitle"), ("ai-title", "aiTitle"), ("topic", "topic")]
    /// Values the engine itself passes over when it picks a title.
    static let placeholderTitles: Set<String> = ["(No content)", "/compact"]

    /// A reported total equal to input + output, or cached tokens nested in the input details, proves that input holds cache
    /// reads and output holds reasoning; otherwise the counts are additive. In keeps cache writes; Cache is cache reads only.
    /// Fresh input keeps its cache writes and output its reasoning; both are also returned on their own.
    static func tokens(_ usage: ProviderJSON) throws -> (input: Int, output: Int, cache: Int, write: Int, reasoning: Int)? {
        func counts(_ keys: [String]) throws -> [Int] { try keys.compactMap { usage[$0] == .null ? nil : try usage[$0].optionalCounter() } }
        func positive(_ keys: [String]) throws -> Int? { let values = try counts(keys); return values.first { $0 > 0 } ?? values.first }
        func nested(_ keys: [String], _ field: String) throws -> Int? {
            guard let key = keys.first(where: { usage[$0] != .null }) else { return nil }
            let values = try (usage[key].arrayValue ?? [usage[key]]).compactMap { $0[field] == .null ? nil : try $0[field].optionalCounter() }
            return values.isEmpty ? nil : try values.reduce(0) { try TokenCount.sum($0, $1) }
        }
        let listed = try positive(["cache_read_input_tokens", "cacheReadInputTokens", "cacheTokens", "prompt_cache_hit_tokens", "cached_tokens"])
        let detailed = try nested(["inputTokensDetails", "input_tokens_details", "prompt_tokens_details"], "cached_tokens")
        let cache = listed ?? detailed ?? 0
        let input = try counts(["input_tokens", "inputTokens", "prompt_tokens"]).first ?? 0
        let output = try counts(["output_tokens", "outputTokens", "completion_tokens"]).first ?? 0
        let write = try positive(["cache_creation_input_tokens", "cacheCreationInputTokens", "cachedWriteTokens", "prompt_cache_write_tokens"]) ?? 0
        let reasoning = try counts(["completion_thinking_tokens", "completionThinkingTokens", "reasoningTokens"]).first ?? 0
        let total = try counts(["total_tokens", "totalTokens"]).first
        let inclusive = try listed == nil && detailed != nil || total == TokenCount.sum(input, output)
        let fresh: Int
        if let miss = try counts(["cachedMissTokens", "cacheMissTokens"]).first {
            fresh = inclusive ? miss : try TokenCount.sum(miss, write)
        } else if inclusive {
            guard cache <= input else { throw ProviderFailure.format }
            fresh = input - cache
        } else { fresh = try TokenCount.sum(input, write) }
        let out = inclusive ? output : try TokenCount.sum(output, reasoning)
        return try TokenCount.sum(fresh, out, cache) > 0 ? (fresh, out, cache, min(write, fresh), min(reasoning, out)) : nil
    }

    static func model(_ json: ProviderJSON) -> String? {
        // Written out rather than as a lazy sequence over the three values: Swift 6.4 fails SIL ownership
        // verification on a borrowed JSONValue inside one, and brings the optimizer down with it.
        nonEmpty(json["providerData"]["model"])
            ?? nonEmpty(json["providerData"]["requestModelId"])
            ?? nonEmpty(json["message"]["model"])
    }

    /// The final completed assistant message of the latest turn, searched in at most the last 1 MiB of a transcript.
    static func lastAssistantMessage(_ url: URL, session: String) -> (id: String, model: String?)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? ProviderFiles.tail(handle, bytes: 1 << 20) else { return nil }
        for line in data.split(separator: 10).reversed() {
            guard let json = try? ProviderJSON.read(Data(line)), json["type"].stringValue == "message",
                  json["sessionId"].stringValue.map({ $0 == session }) != false else { continue }
            if json["role"].stringValue == "user" { return nil }
            guard json["role"].stringValue == "assistant", json["status"].stringValue == "completed" else { continue }
            return nonEmpty(json["providerData"]["messageId"]).map { ($0, model(json)) }
        }
        return nil
    }

    /// Sub-agent transcripts share the parent session; keep the parent's metadata and the overall time span.
    static func merge(_ sessions: [ProviderSession]) -> [ProviderSession] {
        let groups = Dictionary(grouping: sessions, by: \.id)
        return sessions.map { item in
            guard let group = groups[item.id], group.count > 1 else { return item }
            let main = group.first { $0.path?.contains("/subagents/") == false && $0.workspace != nil } ?? group.first { $0.workspace != nil } ?? item
            var item = item
            item.title = main.title; item.workspace = main.workspace; item.path = main.path
            item.startedAt = group.compactMap(\.startedAt).min(); item.lastActivity = group.compactMap(\.lastActivity).max()
            return item
        }
    }

    private static func nonEmpty(_ value: ProviderJSON) -> String? {
        value.stringValue.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    }
}

enum CodeBuddySessions: LocalSessionLayout {
    static let installPaths = [".codebuddy/projects"]
    /// CodeBuddy Code's configuration and data folder: `CODEBUDDY_CONFIG_DIR`, else `~/.codebuddy`. The variable points
    /// both clients at one folder when they share an installation, so a value that names WorkBuddy's own folder (where
    /// `workbuddy.db` and `models.json` live) is WorkBuddy's data; the WorkBuddy source reads it, and this one reads
    /// nowhere rather than counting the same transcripts twice under two vendors.
    static func home(_ home: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let workBuddy = home.appendingPathComponent(".workbuddy")
        if let value = ClientHome.variable("CODEBUDDY_CONFIG_DIR", in: environment) {
            let url = URL(fileURLWithPath: value)
            if url.standardizedFileURL.path != workBuddy.standardizedFileURL.path { return url }
        }
        return home.appendingPathComponent(".codebuddy")
    }
    static func roots(home: URL, environment: [String: String]) -> [URL] { [self.home(home, environment: environment).appendingPathComponent("projects")] }
    static func accepts(_ url: URL) -> Bool { url.pathExtension == "jsonl" }
    static func skips(_ url: URL) -> Bool { url.lastPathComponent == "tool-results" }
    static func read(_ url: URL) throws -> ProviderSessions { try TencentBuddySessions.read(url, source: .codebuddy) }
    static func merge(_ sessions: [ProviderSession]) -> [ProviderSession] { TencentBuddySessions.merge(sessions) }
}

enum WorkBuddySessions: LocalSessionLayout {
    static let installPaths = [".workbuddy/projects"]
    static func roots(home: URL, environment: [String: String]) -> [URL] { [home.appendingPathComponent(".workbuddy/projects")] }
    static func accepts(_ url: URL) -> Bool { url.pathExtension == "jsonl" }
    static func skips(_ url: URL) -> Bool { url.lastPathComponent == "tool-results" }
    static func read(_ url: URL) throws -> ProviderSessions { try TencentBuddySessions.read(url, source: .workbuddy) }
    static func merge(_ sessions: [ProviderSession]) -> [ProviderSession] { names(TencentBuddySessions.merge(sessions)) }

    /// A model's name on every surface: a model the transcripts reached through one of the app's own model entries (a
    /// `custom-local:` route) read as its logged name alone; every other model the app served itself, so its name reads
    /// as "<model> (WorkBuddy)", or "(WB)" where the whole would not fit. The route each call names is the historical
    /// fact in the transcript, so a model reads the same even after its entry was deleted from the app's model list.
    static func displayName(_ model: String, apiReached: Set<String>) -> String {
        if apiReached.contains(model) { return model }
        return model.count + 11 > 32 ? "\(model)（WB）" : "\(model)（WorkBuddy）"
    }

    /// The app keeps a session's name in `workbuddy.db` beside `projects`, where a rename from its sidebar goes: the
    /// name the user gave, else the generated one. Read on every pass, so a rename shows without reparsing transcripts.
    static func names(_ sessions: [ProviderSession]) -> [ProviderSession] {
        guard let path = sessions.lazy.compactMap(\.path).first,
              let projects = sequence(first: URL(fileURLWithPath: path).deletingLastPathComponent(), next: {
                  $0.pathComponents.count > 1 ? $0.deletingLastPathComponent() : nil
              }).first(where: { $0.lastPathComponent == "projects" }),
              let database = try? ReadOnlySQLite(projects.deletingLastPathComponent().appendingPathComponent("workbuddy.db")) else { return sessions }
        let prefix = "\(AdditionalSource.workbuddy.rawValue):"
        let ids = sessions.map { String($0.id.dropFirst(prefix.count)) }
        guard let list = try? JSONSerialization.data(withJSONObject: ids), let json = String(data: list, encoding: .utf8) else { return sessions }
        var titles: [String: String] = [:]
        try? database.rows("SELECT id, custom_title, title FROM sessions WHERE id IN (SELECT value FROM json_each(?))", strings: [json]) { row in
            if let id = ReadOnlySQLite.text(row, 0),
               let title = SessionTitle.named(ReadOnlySQLite.text(row, 1)) ?? SessionTitle.named(ReadOnlySQLite.text(row, 2)) { titles[prefix + id] = title }
        }
        return sessions.map { var item = $0; if let title = titles[item.id] { item.title = title }; return item }
    }

    /// What the app's own metering (`session_usage`) charged each session: the credits its per-model entries add up to,
    /// attributed to the one model whose sessions an entry appears in when every such session called it, with the rest
    /// reported as unattributed rather than guessed. Its `used`/`size` are the context size and limit it metered, in
    /// tokens. `models` is each session's models as its transcript logged them.
    static func credits(sessions: [ProviderSession], models: [String: Set<String>], home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String: SessionCredits] {
        guard let path = sessions.lazy.compactMap(\.path).first,
              let projects = sequence(first: URL(fileURLWithPath: path).deletingLastPathComponent(), next: {
                  $0.pathComponents.count > 1 ? $0.deletingLastPathComponent() : nil
              }).first(where: { $0.lastPathComponent == "projects" }),
              let database = try? ReadOnlySQLite(projects.deletingLastPathComponent().appendingPathComponent("workbuddy.db")) else { return [:] }
        let prefix = "\(AdditionalSource.workbuddy.rawValue):"
        // The metering's entries, keyed as the transcripts key their sessions.
        var entries: [String: (used: Int, size: Int, credits: [String: Double])] = [:]
        do {
            try database.rows("SELECT session_id, used, size, credit_json FROM session_usage WHERE credit_json IS NOT NULL AND credit_json != ''") { row in
                guard let raw = ReadOnlySQLite.text(row, 0), let used = ReadOnlySQLite.text(row, 1).flatMap(Int.init),
                      let size = ReadOnlySQLite.text(row, 2).flatMap(Int.init), let json = ReadOnlySQLite.text(row, 3),
                      let credits = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Double] else { return }
                entries[prefix + raw] = (used, size, credits)
            }
        } catch { return [:] }
        guard !entries.isEmpty else { return [:] }
        // An entry's key names one model when every session the entry appears in called that model and no other.
        var keyed: [String: String] = [:]
        for (key, _) in entries {
            var shared: Set<String>? = nil
            for (id, record) in entries where record.credits[key] != nil {
                guard let called = models[prefix + id] ?? models[id] else { continue }
                shared = shared == nil ? called : shared!.intersection(called)
                if shared?.isEmpty == true { break }
            }
            if let only = shared, only.count == 1 { keyed[key] = only.first! }
        }
        var result: [String: SessionCredits] = [:]
        for (id, record) in entries {
            var byModel: [String: Double] = [:], unattributed = 0.0
            for (key, value) in record.credits {
                if let model = keyed[key] { byModel[model, default: 0] += value } else { unattributed += value }
            }
            result[id] = SessionCredits(total: record.credits.values.reduce(0, +), unattributed: unattributed,
                                        byModel: byModel.mapKeys { "\(AdditionalSource.workbuddy.rawValue)-model:\($0)" },
                                        used: record.used, size: record.size)
        }
        return result
    }
}

extension Dictionary where Key == String {
    /// A map with its keys rewritten; identical keys keep their first value in iteration order, like `mapValues` order.
    fileprivate func mapKeys(_ transform: (Key) -> String) -> [Key: Value] {
        var mapped: [Key: Value] = [:]
        for (key, value) in self { mapped[transform(key)] = value }
        return mapped
    }
}
