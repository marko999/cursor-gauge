import Foundation

/// One usage event from the unofficial dashboard events endpoint.
public struct UsageEvent: Equatable, Sendable {
    public var model: String
    /// Raw kind string from Cursor (e.g. `USAGE_BASED` vs included variants).
    public var kind: String
    public var timestamp: Date?
    public var chargedCents: Double?
    /// Preserved separately — unit is not safely treated as USD.
    public var requestsCosts: Double?
    public var usageBasedCosts: Double?
    public var cursorTokenFee: Double?
    public var tokenUsageTotalCents: Double?
    public var totalTokens: Double?

    public init(
        model: String,
        kind: String,
        timestamp: Date? = nil,
        chargedCents: Double? = nil,
        requestsCosts: Double? = nil,
        usageBasedCosts: Double? = nil,
        cursorTokenFee: Double? = nil,
        tokenUsageTotalCents: Double? = nil,
        totalTokens: Double? = nil
    ) {
        self.model = model
        self.kind = kind
        self.timestamp = timestamp
        self.chargedCents = chargedCents
        self.requestsCosts = requestsCosts
        self.usageBasedCosts = usageBasedCosts
        self.cursorTokenFee = cursorTokenFee
        self.tokenUsageTotalCents = tokenUsageTotalCents
        self.totalTokens = totalTokens
    }

    public var isUsageBased: Bool {
        kind.uppercased().contains("USAGE_BASED")
    }
}

/// Per-model attribution built from dashboard events (unofficial semantics).
public struct ModelUsageAggregate: Equatable, Sendable {
    public var model: String
    public var eventCount: Int
    public var includedAttributedCents: Double
    public var onDemandAttributedCents: Double
    public var totalAttributedCents: Double
    public var totalTokens: Double
    /// Sum of `requestsCosts` when present; not labeled as dollars.
    public var requestsCostsSum: Double

    public init(
        model: String,
        eventCount: Int = 0,
        includedAttributedCents: Double = 0,
        onDemandAttributedCents: Double = 0,
        totalAttributedCents: Double = 0,
        totalTokens: Double = 0,
        requestsCostsSum: Double = 0
    ) {
        self.model = model
        self.eventCount = eventCount
        self.includedAttributedCents = includedAttributedCents
        self.onDemandAttributedCents = onDemandAttributedCents
        self.totalAttributedCents = totalAttributedCents
        self.totalTokens = totalTokens
        self.requestsCostsSum = requestsCostsSum
    }
}

public enum PaginationDecision: Equatable, Sendable {
    case fetchNext(page: Int)
    case stop(reason: String)
}

/// Pure pagination termination for usage-event pages.
public func nextUsageEventsPage(
    currentPage: Int,
    pageSize: Int,
    returnedCount: Int,
    maxPages: Int
) -> PaginationDecision {
    guard currentPage >= 1, pageSize > 0, maxPages > 0 else {
        return .stop(reason: "invalid-pagination-args")
    }
    if currentPage >= maxPages {
        return .stop(reason: "max-pages")
    }
    if returnedCount <= 0 {
        return .stop(reason: "empty-page")
    }
    if returnedCount < pageSize {
        return .stop(reason: "short-page")
    }
    return .fetchNext(page: currentPage + 1)
}

private func asRecord(_ value: Any?) -> [String: Any]? {
    value as? [String: Any]
}

private func asFiniteNumber(_ value: Any?) -> Double? {
    switch value {
    case let n as Double where n.isFinite:
        return n
    case let n as Int:
        return Double(n)
    case let n as NSNumber:
        let d = n.doubleValue
        return d.isFinite ? d : nil
    case let s as String:
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let d = Double(trimmed), d.isFinite else { return nil }
        return d
    default:
        return nil
    }
}

private func parseEventTimestamp(_ value: Any?) -> Date? {
    if let s = value as? String, s.range(of: #"^\d+$"#, options: .regularExpression) != nil {
        if let ms = Double(s), ms > 0 {
            return Date(timeIntervalSince1970: ms / 1000)
        }
    }
    if let n = asFiniteNumber(value), n > 0 {
        let ms = n < 1e12 ? n * 1000 : n
        return Date(timeIntervalSince1970: ms / 1000)
    }
    if let s = value as? String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatter.date(from: s) { return d }
        formatter.formatOptions = [.withInternetDateTime]
        if let d = formatter.date(from: s) { return d }
    }
    return nil
}

private func tokenUsageTotalCents(from tokenUsage: Any?) -> Double? {
    guard let record = asRecord(tokenUsage) else { return nil }
    return asFiniteNumber(record["totalCents"])
        ?? asFiniteNumber(record["totalCostCents"])
}

private func tokenUsageTotalTokens(from tokenUsage: Any?) -> Double? {
    guard let record = asRecord(tokenUsage) else { return nil }
    if let total = asFiniteNumber(record["totalTokens"]) ?? asFiniteNumber(record["total"]) {
        return total
    }
    let input = asFiniteNumber(record["inputTokens"]) ?? asFiniteNumber(record["input"]) ?? 0
    let output = asFiniteNumber(record["outputTokens"]) ?? asFiniteNumber(record["output"]) ?? 0
    let cacheWrite = asFiniteNumber(record["cacheWriteTokens"]) ?? 0
    let cacheRead = asFiniteNumber(record["cacheReadTokens"]) ?? 0
    let sum = input + output + cacheWrite + cacheRead
    return sum > 0 ? sum : nil
}

/// Parse a single event object from `usageEventsDisplay`.
public func parseUsageEvent(_ json: Any?) -> UsageEvent? {
    guard let root = asRecord(json) else { return nil }
    let model =
        (root["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        ?? (root["modelName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let model, !model.isEmpty else { return nil }

    let kind =
        (root["kind"] as? String)
        ?? (root["usageKind"] as? String)
        ?? (root["type"] as? String)
        ?? "unknown"

    return UsageEvent(
        model: model,
        kind: kind,
        timestamp: parseEventTimestamp(root["timestamp"] ?? root["createdAt"] ?? root["time"]),
        chargedCents: asFiniteNumber(root["chargedCents"]),
        requestsCosts: asFiniteNumber(root["requestsCosts"] ?? root["requestCosts"]),
        usageBasedCosts: asFiniteNumber(root["usageBasedCosts"]),
        cursorTokenFee: asFiniteNumber(root["cursorTokenFee"]),
        tokenUsageTotalCents: tokenUsageTotalCents(from: root["tokenUsage"]),
        totalTokens: tokenUsageTotalTokens(from: root["tokenUsage"])
            ?? asFiniteNumber(root["totalTokens"])
    )
}

/// Extract the `usageEventsDisplay` array from a dashboard events response.
public func parseUsageEventsResponse(_ json: Any?) -> [UsageEvent] {
    guard let root = asRecord(json) else { return [] }
    let list =
        root["usageEventsDisplay"] as? [Any]
        ?? root["usageEvents"] as? [Any]
        ?? []
    return list.compactMap(parseUsageEvent)
}

/**
 Attributed cost in cents for one event.

 - Prefer `chargedCents` when meaningful (> 0).
 - For included (non-USAGE_BASED) events with absent/zero `chargedCents`,
   derive from `tokenUsage.totalCents + cursorTokenFee`.
 - Do not also add token cents when `chargedCents` was used (no double count).
 - `requestsCosts` is never treated as USD here.
 */
public func attributedCostCents(for event: UsageEvent) -> Double {
    if let charged = event.chargedCents, charged > 0 {
        return charged
    }

    if !event.isUsageBased {
        let tokenCents = event.tokenUsageTotalCents ?? 0
        let fee = event.cursorTokenFee ?? 0
        let derived = tokenCents + fee
        if derived > 0 { return derived }
        return 0
    }

    // USAGE_BASED with no meaningful chargedCents: try usageBasedCosts as dollars → cents
    // only when the value looks like a dollar amount (not an opaque request unit).
    if let ub = event.usageBasedCosts, ub > 0 {
        // Heuristic: fractional or small magnitudes are dollars; large integers may already be cents.
        if ub != floor(ub) || ub < 1000 {
            return ub * 100
        }
        return ub
    }

    let tokenCents = event.tokenUsageTotalCents ?? 0
    let fee = event.cursorTokenFee ?? 0
    return tokenCents + fee
}

/// Keep events whose timestamp falls within `[start, end]` (inclusive). Nil bounds skip that side.
public func filterEventsToBillingCycle(
    _ events: [UsageEvent],
    start: Date?,
    end: Date?
) -> [UsageEvent] {
    guard start != nil || end != nil else { return events }
    return events.filter { event in
        guard let ts = event.timestamp else {
            // Keep undated events when the server already scoped the page; avoid silent drops.
            return true
        }
        if let start, ts < start { return false }
        if let end, ts > end { return false }
        return true
    }
}

/// Aggregate events by model; sort by total attributed cost descending.
public func aggregateUsageEventsByModel(_ events: [UsageEvent]) -> [ModelUsageAggregate] {
    var map: [String: ModelUsageAggregate] = [:]

    for event in events {
        var row = map[event.model] ?? ModelUsageAggregate(model: event.model)
        row.eventCount += 1
        let cents = attributedCostCents(for: event)
        if event.isUsageBased {
            row.onDemandAttributedCents += cents
        } else {
            row.includedAttributedCents += cents
        }
        row.totalAttributedCents = row.includedAttributedCents + row.onDemandAttributedCents
        if let tokens = event.totalTokens {
            row.totalTokens += tokens
        }
        if let req = event.requestsCosts {
            row.requestsCostsSum += req
        }
        map[event.model] = row
    }

    return map.values.sorted { lhs, rhs in
        if lhs.totalAttributedCents != rhs.totalAttributedCents {
            return lhs.totalAttributedCents > rhs.totalAttributedCents
        }
        return lhs.model.localizedCaseInsensitiveCompare(rhs.model) == .orderedAscending
    }
}
