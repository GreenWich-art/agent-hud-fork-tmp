import Foundation

/// What WorkBuddy's own metering charged one session: the credits its record names, the part the transcripts could pin
/// on one model, and the rest, reported as unattributed rather than guessed. `used`/`size` are the context size and its
/// limit as the app metered the session, in tokens.
public struct SessionCredits: Hashable, Codable, Sendable {
    /// The session's credits, summed over its record's per-model entries.
    public let total: Double
    /// The part no one model could be pinned on.
    public let unattributed: Double
    /// Credits per consumer id (`workbuddy-model:<model>`), from entries that only ever name that model.
    public let byModel: [String: Double]
    /// The context size the app's metering recorded for the session, in tokens.
    public let used: Int?
    /// The context limit that metering ran against, in tokens.
    public let size: Int?

    public init(total: Double, unattributed: Double, byModel: [String: Double], used: Int? = nil, size: Int? = nil) {
        self.total = total; self.unattributed = unattributed; self.byModel = byModel
        self.used = used; self.size = size
    }

    /// Two decimals, with the noise a floating-point sum leaves behind rounded away rather than shown.
    public var text: String { Self.format(total) }

    /// `value` with two decimals; values below that still show their two decimals rather than a bare zero.
    public static func format(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return String(format: "%.2f", rounded)
    }

    /// The attributed share of the total, 0…1; nil when nothing was charged.
    public var attributedShare: Double? {
        total > 0 ? max(0, 1 - unattributed / total) : nil
    }
}
