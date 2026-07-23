import Foundation

public enum ValueKind: Equatable, Sendable {
    case cents
    case requests
}

public enum UsageSource: String, Equatable, Sendable {
    case getCurrentPeriodUsage = "GetCurrentPeriodUsage"
    case authUsage = "auth/usage"
}

public struct PeriodUsage: Equatable, Sendable {
    public var kind: ValueKind
    public var used: Double
    public var limit: Double
    public var remaining: Double
    public var onDemandUsed: Double?
    public var onDemandLimit: Double?
    public var onDemandRemaining: Double?
    public var periodStart: Date?
    public var periodEnd: Date?
    public var totalPercentUsed: Double?
    public var autoPercentUsed: Double?
    public var apiPercentUsed: Double?
    public var displayMessage: String?
    public var source: UsageSource

    public init(
        kind: ValueKind,
        used: Double,
        limit: Double,
        remaining: Double,
        onDemandUsed: Double? = nil,
        onDemandLimit: Double? = nil,
        onDemandRemaining: Double? = nil,
        periodStart: Date? = nil,
        periodEnd: Date? = nil,
        totalPercentUsed: Double? = nil,
        autoPercentUsed: Double? = nil,
        apiPercentUsed: Double? = nil,
        displayMessage: String? = nil,
        source: UsageSource
    ) {
        self.kind = kind
        self.used = used
        self.limit = limit
        self.remaining = remaining
        self.onDemandUsed = onDemandUsed
        self.onDemandLimit = onDemandLimit
        self.onDemandRemaining = onDemandRemaining
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.totalPercentUsed = totalPercentUsed
        self.autoPercentUsed = autoPercentUsed
        self.apiPercentUsed = apiPercentUsed
        self.displayMessage = displayMessage
        self.source = source
    }
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

private func parseMsTimestamp(_ value: Any?) -> Date? {
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
        if let d = DateFormatter.cacheLocale.date(from: s) { return d }
    }
    return nil
}

private enum DateFormatter {
    static let cacheLocale: Foundation.DateFormatter = {
        let f = Foundation.DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return f
    }()
}

public func formatUsdFromCents(_ cents: Double) -> String {
    let dollars = cents / 100
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    formatter.locale = Locale.current
    return formatter.string(from: NSNumber(value: dollars)) ?? String(format: "$%.2f", dollars)
}

/// Compact status-bar currency (keeps menu-bar width small).
public func formatCompactUsdFromCents(_ cents: Double) -> String {
    let dollars = cents / 100
    guard dollars.isFinite else { return "$?" }
    if abs(dollars - dollars.rounded()) < 0.05 {
        return String(format: "$%.0f", dollars.rounded())
    }
    if abs(dollars) >= 100 {
        return String(format: "$%.0f", dollars.rounded())
    }
    return String(format: "$%.1f", dollars)
}

public func formatTokenCount(_ tokens: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 0
    return formatter.string(from: NSNumber(value: tokens)) ?? String(Int(tokens))
}

/// Format a usage amount according to whether the plan reports cents or requests.
public func formatUsageAmount(_ value: Double, kind: ValueKind) -> String {
    switch kind {
    case .cents:
        return formatUsdFromCents(value)
    case .requests:
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(value))"
        }
        return String(value)
    }
}

/// Clamped 0…1 progress for determinate bars (`used / limit`).
public func usageProgressFraction(used: Double, limit: Double) -> Double {
    guard limit > 0, used.isFinite, limit.isFinite else { return 0 }
    return max(0, min(1, used / limit))
}

/// Percentage of the included plan consumed, derived from `used / limit`.
public func formatPlanUsedPercent(used: Double, limit: Double) -> String {
    let percent = usageProgressFraction(used: used, limit: limit) * 100
    return String(format: "%.1f%%", percent)
}

/// Compact “Updated …” label for the popover header.
public func formatUpdatedLabel(_ date: Date, now: Date = Date()) -> String {
    let elapsed = max(0, now.timeIntervalSince(date))
    if elapsed < 45 {
        return "Updated just now"
    }
    if elapsed < 90 {
        return "Updated 1m ago"
    }
    if elapsed < 3600 {
        return "Updated \(Int(elapsed / 60))m ago"
    }
    if elapsed < 5400 {
        return "Updated 1h ago"
    }
    if elapsed < 86_400 {
        return "Updated \(Int(elapsed / 3600))h ago"
    }
    return "Updated \(date.formatted(date: .abbreviated, time: .shortened))"
}

/// Secondary line for a model aggregate row (spend / tokens / events).
public func formatModelRowDetail(_ row: ModelUsageAggregate) -> String {
    var parts = [
        "\(formatUsdFromCents(row.totalAttributedCents)) total",
        "\(row.eventCount) events",
    ]
    if row.includedAttributedCents > 0 {
        parts.append("incl \(formatUsdFromCents(row.includedAttributedCents))")
    }
    if row.onDemandAttributedCents > 0 {
        parts.append("on-demand \(formatUsdFromCents(row.onDemandAttributedCents))")
    }
    if row.totalTokens > 0 {
        parts.append("\(formatTokenCount(row.totalTokens)) tokens")
    }
    if row.requestsCostsSum > 0 {
        parts.append(String(format: "reqCost %.2f", row.requestsCostsSum))
    }
    return parts.joined(separator: " · ")
}

/// Human-readable Launch at Login status for Settings (no secrets).
public enum LaunchAtLoginDisplayState: String, Equatable, Sendable {
    case enabled
    case notRegistered
    case requiresApproval
    case notFound
    case unknown
}

public func formatLaunchAtLoginStatus(_ state: LaunchAtLoginDisplayState) -> String {
    switch state {
    case .enabled:
        return "Registered — opens at login"
    case .notRegistered:
        return "Not registered"
    case .requiresApproval:
        return "Needs approval in System Settings → Login Items"
    case .notFound:
        return "App not found for registration"
    case .unknown:
        return "Status unavailable"
    }
}

/// Short note when Launch at Login is unreliable outside `/Applications`.
public func formatLaunchAtLoginLimitation(isInApplications: Bool) -> String {
    if isInApplications {
        return "Uses macOS ServiceManagement (SMAppService)."
    }
    return "Launch at Login works reliably when this app is installed in /Applications. Running from a local build folder may fail registration."
}

/// Percent of included allowance remaining (0–100), when limit > 0.
public func remainingPercent(of usage: PeriodUsage) -> Double? {
    guard usage.limit > 0 else { return nil }
    return max(0, min(100, (usage.remaining / usage.limit) * 100))
}

/// Parse GetCurrentPeriodUsage or legacy /auth/usage JSON into a normalized snapshot.
public func parsePeriodUsageResponse(_ json: Any?) -> PeriodUsage? {
    guard let root = asRecord(json) else { return nil }

    if let planUsage = asRecord(root["planUsage"]) {
        let used = asFiniteNumber(planUsage["includedSpend"]) ?? asFiniteNumber(planUsage["totalSpend"])
        let limit = asFiniteNumber(planUsage["limit"])
        let remaining =
            asFiniteNumber(planUsage["remaining"])
            ?? (used != nil && limit != nil ? max(0, limit! - used!) : nil)

        if let used, let limit, let remaining {
            let spendLimit = asRecord(root["spendLimitUsage"])
            let onDemandUsed =
                asFiniteNumber(spendLimit?["individualUsed"])
                ?? asFiniteNumber(spendLimit?["totalSpend"])
            let onDemandLimit = asFiniteNumber(spendLimit?["individualLimit"])
            let onDemandRemaining =
                asFiniteNumber(spendLimit?["individualRemaining"])
                ?? (onDemandUsed != nil && onDemandLimit != nil
                    ? max(0, onDemandLimit! - onDemandUsed!) : nil)

            return PeriodUsage(
                kind: .cents,
                used: used,
                limit: limit,
                remaining: remaining,
                onDemandUsed: onDemandUsed,
                onDemandLimit: onDemandLimit,
                onDemandRemaining: onDemandRemaining,
                periodStart: parseMsTimestamp(root["billingCycleStart"]),
                periodEnd: parseMsTimestamp(root["billingCycleEnd"]),
                totalPercentUsed: asFiniteNumber(planUsage["totalPercentUsed"]),
                autoPercentUsed: asFiniteNumber(planUsage["autoPercentUsed"]),
                apiPercentUsed: asFiniteNumber(planUsage["apiPercentUsed"]),
                displayMessage: root["displayMessage"] as? String,
                source: .getCurrentPeriodUsage
            )
        }
    }

    let startOfMonth = parseMsTimestamp(root["startOfMonth"])
    let preferredKeys = ["gpt-4", "gpt-4o", "default", "claude-3-5-sonnet"]
    let otherKeys = root.keys.filter { $0 != "startOfMonth" }
    let candidates = preferredKeys + otherKeys.filter { !preferredKeys.contains($0) }

    for key in candidates {
        guard let bucket = asRecord(root[key]) else { continue }
        guard let used = asFiniteNumber(bucket["numRequests"]),
              let limit = asFiniteNumber(bucket["maxRequestUsage"]),
              limit > 0
        else { continue }
        return PeriodUsage(
            kind: .requests,
            used: used,
            limit: limit,
            remaining: max(0, limit - used),
            periodStart: startOfMonth,
            source: .authUsage
        )
    }

    return nil
}

/// Compact menu-bar title text (no IDE icon glyphs).
public func formatStatusText(
    _ usage: PeriodUsage,
    displayMode: StatusDisplayMode = .dollarsRemaining
) -> String {
    let useOnDemand =
        usage.kind == .cents
        && usage.remaining <= 0
        && (usage.onDemandLimit ?? 0) > 0
    let remaining = useOnDemand
        ? usage.onDemandRemaining
            ?? max(0, (usage.onDemandLimit ?? 0) - (usage.onDemandUsed ?? 0))
        : usage.remaining
    let limit = useOnDemand ? (usage.onDemandLimit ?? 0) : usage.limit
    let suffix = useOnDemand ? " OD" : ""

    switch displayMode {
    case .dollarsRemaining:
        switch usage.kind {
        case .cents:
            return "\(formatCompactUsdFromCents(remaining))\(suffix)"
        case .requests:
            let rem = remaining.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(remaining))
                : String(remaining)
            return "\(rem)\(suffix)"
        }
    case .percentRemaining:
        if limit > 0 {
            let pct = max(0, min(100, remaining / limit * 100))
            let rounded = pct.truncatingRemainder(dividingBy: 1) < 0.05
                ? String(format: "%.0f%%%@", pct, suffix)
                : String(format: "%.1f%%%@", pct, suffix)
            return rounded
        }
        return "?%\(suffix)"
    }
}

public func formatOverviewLines(_ usage: PeriodUsage, lastUpdated: Date) -> [String] {
    var lines: [String] = []

    switch usage.kind {
    case .cents:
        lines.append("Included used: \(formatUsdFromCents(usage.used))")
        lines.append("Included limit: \(formatUsdFromCents(usage.limit))")
        lines.append("Included remaining: \(formatUsdFromCents(usage.remaining))")
    case .requests:
        lines.append("Included used: \(Int(usage.used)) requests")
        lines.append("Included limit: \(Int(usage.limit)) requests")
        lines.append("Included remaining: \(Int(usage.remaining)) requests")
    }

    if usage.onDemandLimit != nil || usage.onDemandUsed != nil || usage.onDemandRemaining != nil {
        switch usage.kind {
        case .cents:
            lines.append("On-demand used: \(formatUsdFromCents(usage.onDemandUsed ?? 0))")
            lines.append("On-demand limit: \(usage.onDemandLimit.map(formatUsdFromCents) ?? "—")")
            lines.append("On-demand remaining: \(usage.onDemandRemaining.map(formatUsdFromCents) ?? "—")")
        case .requests:
            lines.append("On-demand used: \(usage.onDemandUsed.map { String(Int($0)) } ?? "—")")
            lines.append("On-demand limit: \(usage.onDemandLimit.map { String(Int($0)) } ?? "—")")
            lines.append("On-demand remaining: \(usage.onDemandRemaining.map { String(Int($0)) } ?? "—")")
        }
    }

    if let pct = usage.totalPercentUsed {
        lines.append(String(format: "Total used: %.1f%%", pct))
    }
    if let pct = usage.autoPercentUsed {
        lines.append(String(format: "Auto: %.1f%%", pct))
    }
    if let pct = usage.apiPercentUsed {
        lines.append(String(format: "API: %.1f%%", pct))
    }

    if let start = usage.periodStart {
        lines.append("Period start: \(start.formatted(date: .abbreviated, time: .shortened))")
    }
    if let end = usage.periodEnd {
        lines.append("Resets: \(end.formatted(date: .abbreviated, time: .shortened))")
    }

    if let message = usage.displayMessage, !message.isEmpty {
        lines.append(message)
    }

    lines.append("Updated: \(lastUpdated.formatted(date: .abbreviated, time: .standard))")
    lines.append("Source: \(usage.source.rawValue)")
    return lines
}

/// Back-compat name used by older menu UI / tests.
public func formatMenuDetailLines(_ usage: PeriodUsage, lastUpdated: Date) -> [String] {
    formatOverviewLines(usage, lastUpdated: lastUpdated)
}

public func formatModelAggregateLines(_ rows: [ModelUsageAggregate]) -> [String] {
    if rows.isEmpty {
        return [
            "No usage events in the current billing cycle.",
            "Attribution uses unofficial dashboard event fields — not an invoice.",
        ]
    }
    var lines: [String] = [
        "Dashboard event attribution (unofficial; not an invoice).",
    ]
    for row in rows {
        var parts = [
            row.model,
            "events \(row.eventCount)",
            "incl \(formatUsdFromCents(row.includedAttributedCents))",
            "on-demand \(formatUsdFromCents(row.onDemandAttributedCents))",
            "total \(formatUsdFromCents(row.totalAttributedCents))",
        ]
        if row.totalTokens > 0 {
            parts.append("tokens \(formatTokenCount(row.totalTokens))")
        }
        if row.requestsCostsSum > 0 {
            parts.append(String(format: "reqCost %.2f (units)", row.requestsCostsSum))
        }
        lines.append(parts.joined(separator: " · "))
    }
    return lines
}

public func formatErrorStatus(_ message: String) -> (title: String, details: [String]) {
    (
        title: "CG ?",
        details: [
            "CursorGauge",
            message,
            "Sign in to Cursor on this Mac if needed, then Refresh.",
        ]
    )
}

public func formatLoadingStatus() -> (title: String, details: [String]) {
    (
        title: "CG…",
        details: ["Refreshing Cursor plan usage…"]
    )
}
