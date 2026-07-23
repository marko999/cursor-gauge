import Foundation
import CursorGaugeCore

// Lightweight test runner for Command Line Tools (no XCTest framework).

private var failures = 0

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String,
    file: StaticString = #fileID,
    line: UInt = #line
) {
    if !condition() {
        failures += 1
        fputs("FAIL \(file):\(line): \(message)\n", stderr)
    }
}

private func expectEqual<T: Equatable>(
    _ a: T,
    _ b: T,
    _ message: String = "",
    file: StaticString = #fileID,
    line: UInt = #line
) {
    if a != b {
        failures += 1
        fputs("FAIL \(file):\(line): expected \(b), got \(a). \(message)\n", stderr)
    }
}

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func makeTestJWT(sub: String) -> String {
    let header = base64URL(Data(#"{"alg":"none","typ":"JWT"}"#.utf8))
    let payloadJSON = #"{"sub":"\#(sub)"}"#
    let payload = base64URL(Data(payloadJSON.utf8))
    let sig = base64URL(Data("signaturepartlongenoughforjwtcheck".utf8))
    return "\(header).\(payload).\(sig)"
}

// MARK: - parse GetCurrentPeriodUsage

do {
    let json: [String: Any] = [
        "billingCycleStart": "1784717779000",
        "billingCycleEnd": "1787396179000",
        "planUsage": [
            "totalSpend": 24740,
            "includedSpend": 24740,
            "remaining": 15260,
            "limit": 40000,
            "autoPercentUsed": 8.3,
            "apiPercentUsed": 16,
            "totalPercentUsed": 9.9,
        ],
        "spendLimitUsage": [
            "individualLimit": 30000,
            "individualRemaining": 30000,
            "limitType": "user",
        ],
        "displayMessage": "You've used 10% of your usage limit",
        "enabled": true,
    ]
    if let usage = parsePeriodUsageResponse(json) {
        expectEqual(usage.kind, .cents)
        expectEqual(usage.used, 24740)
        expectEqual(usage.limit, 40000)
        expectEqual(usage.remaining, 15260)
        expectEqual(usage.onDemandLimit, 30000)
        expectEqual(usage.onDemandRemaining, 30000)
        expectEqual(usage.source, .getCurrentPeriodUsage)
        expect(usage.periodStart != nil, "periodStart")
        expect(usage.periodEnd != nil, "periodEnd")
        if let pct = remainingPercent(of: usage) {
            expect(abs(pct - 38.15) < 0.01, "remaining percent ~38.15")
        } else {
            failures += 1
            fputs("FAIL: expected remaining percent\n", stderr)
        }
    } else {
        failures += 1
        fputs("FAIL: expected parsed cents usage\n", stderr)
    }
}

// MARK: - legacy auth/usage

do {
    let json: [String: Any] = [
        "startOfMonth": "2026-07-22T10:56:19.000Z",
        "gpt-4": [
            "numRequests": 12,
            "maxRequestUsage": 500,
        ],
    ]
    if let usage = parsePeriodUsageResponse(json) {
        expectEqual(usage.kind, .requests)
        expectEqual(usage.used, 12)
        expectEqual(usage.limit, 500)
        expectEqual(usage.remaining, 488)
        expectEqual(usage.source, .authUsage)
    } else {
        failures += 1
        fputs("FAIL: expected parsed request usage\n", stderr)
    }
}

// MARK: - unrecognized

expect(parsePeriodUsageResponse(nil) == nil, "nil payload")
expect(parsePeriodUsageResponse([:] as [String: Any]) == nil, "empty object")
expect(
    parsePeriodUsageResponse(["planUsage": ["foo": 1]] as [String: Any]) == nil,
    "bad planUsage"
)

// MARK: - display preference formatting

do {
    let json: [String: Any] = [
        "billingCycleStart": "1784717779000",
        "billingCycleEnd": "1787396179000",
        "planUsage": [
            "includedSpend": 1000,
            "remaining": 9000,
            "limit": 10000,
            "totalPercentUsed": 10,
        ],
        "spendLimitUsage": [
            "individualUsed": 0,
            "individualLimit": 5000,
            "individualRemaining": 5000,
        ],
    ]
    if let usage = parsePeriodUsageResponse(json) {
        let dollars = formatStatusText(usage, displayMode: .dollarsRemaining)
        expect(dollars.contains("left"), "status contains left")
        expect(!dollars.localizedCaseInsensitiveContains("Bearer"), "no Bearer in status")
        expect(!dollars.contains("eyJ"), "no jwt prefix in status")

        let percent = formatStatusText(usage, displayMode: .percentRemaining)
        expect(percent.contains("% left"), "percent mode")
        expect(percent.hasPrefix("90"), "90% remaining")

        let lines = formatOverviewLines(
            usage,
            lastUpdated: Date(timeIntervalSince1970: 1_753_264_800)
        )
        let joined = lines.joined(separator: "\n")
        expect(joined.contains("Included used:"), "details Included used")
        expect(joined.contains("On-demand"), "details On-demand")
        expect(joined.contains("Resets:"), "details Resets")
        expect(!joined.localizedCaseInsensitiveContains("Authorization"), "no Authorization")
        expect(!joined.contains("eyJ"), "no jwt in details")
    } else {
        failures += 1
        fputs("FAIL: expected usage for formatter test\n", stderr)
    }
}

do {
    if let usage = parsePeriodUsageResponse([
        "gpt-4": ["numRequests": 1, "maxRequestUsage": 10],
    ] as [String: Any]) {
        expectEqual(formatStatusText(usage, displayMode: .dollarsRemaining), "9 left")
        expectEqual(formatStatusText(usage, displayMode: .percentRemaining), "90% left")
    } else {
        failures += 1
        fputs("FAIL: request status parse\n", stderr)
    }
}

do {
    let err = formatErrorStatus("Not signed in")
    expect(err.title.contains("CursorGauge"), "error title")
    expect(err.details.contains(where: { $0.contains("Not signed in") }), "error detail")
    expect(!err.details.joined().contains("eyJ"), "no jwt in error")
}

// MARK: - preferences defaults (in-memory suite)

do {
    let suiteName = "cursor-gauge-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    expectEqual(AppPreferences.displayMode(defaults: defaults), .dollarsRemaining, "default mode")
    AppPreferences.setDisplayMode(.percentRemaining, defaults: defaults)
    expectEqual(AppPreferences.displayMode(defaults: defaults), .percentRemaining, "persisted mode")
    AppPreferences.setDisplayMode(.dollarsRemaining, defaults: defaults)
    expectEqual(AppPreferences.displayMode(defaults: defaults), .dollarsRemaining, "restored mode")
}

// MARK: - UI formatting helpers (pure)

expectEqual(usageProgressFraction(used: 25, limit: 100), 0.25, "progress 25%")
expectEqual(usageProgressFraction(used: 150, limit: 100), 1.0, "progress clamp high")
expectEqual(usageProgressFraction(used: -5, limit: 100), 0.0, "progress clamp low")
expectEqual(usageProgressFraction(used: 10, limit: 0), 0.0, "progress zero limit")
expectEqual(formatPlanUsedPercent(used: 31420, limit: 40000), "78.5%", "computed plan used")
expect(formatUsageAmount(1525, kind: .cents).contains("15"), "cents amount")
expectEqual(formatUsageAmount(12, kind: .requests), "12", "requests amount")

do {
    let now = Date(timeIntervalSince1970: 1_000_000)
    expectEqual(
        formatUpdatedLabel(Date(timeIntervalSince1970: 1_000_000 - 10), now: now),
        "Updated just now"
    )
    expectEqual(
        formatUpdatedLabel(Date(timeIntervalSince1970: 1_000_000 - 120), now: now),
        "Updated 2m ago"
    )
    expectEqual(
        formatUpdatedLabel(Date(timeIntervalSince1970: 1_000_000 - 7200), now: now),
        "Updated 2h ago"
    )
}

expectEqual(
    formatLaunchAtLoginStatus(.enabled),
    "Registered — opens at login"
)
expect(
    formatLaunchAtLoginStatus(.requiresApproval).localizedCaseInsensitiveContains("approval"),
    "approval status"
)
expect(
    formatLaunchAtLoginLimitation(isInApplications: false).contains("/Applications"),
    "limitation mentions Applications"
)
expect(
    !formatLaunchAtLoginLimitation(isInApplications: true).contains("local build"),
    "in-apps hint is short"
)

do {
    let row = ModelUsageAggregate(
        model: "claude-test",
        eventCount: 3,
        includedAttributedCents: 100,
        onDemandAttributedCents: 50,
        totalAttributedCents: 150,
        totalTokens: 1000,
        requestsCostsSum: 1.25
    )
    let detail = formatModelRowDetail(row)
    expect(detail.contains("events"), "model detail events")
    expect(detail.contains("tokens"), "model detail tokens")
    expect(detail.localizedCaseInsensitiveContains("total"), "model detail total")
    expect(!detail.contains("eyJ"), "no jwt in model detail")
}

// MARK: - JWT subject / cookie construction (no secrets printed)

do {
    let token = makeTestJWT(sub: "user_abc")
    expect(looksLikeJwt(token), "jwt shape")
    expectEqual(jwtSubject(from: token), "user_abc")
    if let cookie = makeDashboardSessionCookieValue(token: token) {
        expect(cookie.contains("user_abc"), "cookie encodes sub")
        expect(cookie.contains("%3A%3A"), "colon encoded")
        expect(!cookie.contains("::"), "raw colon absent")
        expect(!cookie.contains(" "), "no spaces in cookie value")
    } else {
        failures += 1
        fputs("FAIL: expected cookie value\n", stderr)
    }
    expect(makeDashboardSessionCookieValue(token: "not-a-jwt") == nil, "reject non-jwt cookie")
}

expect(!looksLikeJwt("not-a-jwt"), "reject non-jwt")
expect(!looksLikeJwt("a.b"), "reject short")

expectEqual(
    resolveCursorStateDbPath(home: "/Users/example"),
    "/Users/example/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
)

// MARK: - event parsing + attribution + aggregation

do {
    let included: [String: Any] = [
        "model": "claude-4-sonnet",
        "kind": "INCLUDED",
        "timestamp": "1785000000000",
        "chargedCents": 0,
        "requestsCosts": 1.5,
        "cursorTokenFee": 10,
        "tokenUsage": [
            "totalCents": 90,
            "inputTokens": 100,
            "outputTokens": 50,
            "cacheWriteTokens": 25,
            "cacheReadTokens": 75,
        ],
    ]
    let onDemand: [String: Any] = [
        "model": "claude-4-sonnet",
        "kind": "USAGE_BASED",
        "timestamp": "1785100000000",
        "chargedCents": 250,
        "usageBasedCosts": 2.5,
        "tokenUsage": [
            "totalCents": 200,
            "totalTokens": 400,
        ],
    ]
    let other: [String: Any] = [
        "model": "gpt-5",
        "kind": "USAGE_BASED",
        "timestamp": "1785200000000",
        "chargedCents": 100,
        "tokenUsage": ["totalTokens": 80],
    ]

    if let e1 = parseUsageEvent(included),
       let e2 = parseUsageEvent(onDemand),
       let e3 = parseUsageEvent(other)
    {
        expect(!e1.isUsageBased, "included kind")
        expect(e2.isUsageBased, "usage based kind")
        expectEqual(e1.totalTokens, 250, "input, output, cache write, and cache read tokens")
        expectEqual(attributedCostCents(for: e1), 100, "derived included = totalCents+fee")
        expectEqual(attributedCostCents(for: e2), 250, "prefer chargedCents")

        // chargedCents meaningful should not double-count token cents
        let chargedOnly = UsageEvent(
            model: "x",
            kind: "INCLUDED",
            chargedCents: 40,
            cursorTokenFee: 9,
            tokenUsageTotalCents: 30
        )
        expectEqual(attributedCostCents(for: chargedOnly), 40, "no double count")

        let rows = aggregateUsageEventsByModel([e1, e2, e3])
        expectEqual(rows.count, 2, "two models")
        expectEqual(rows[0].model, "claude-4-sonnet", "sorted by total desc")
        expectEqual(rows[0].eventCount, 2)
        expectEqual(rows[0].includedAttributedCents, 100)
        expectEqual(rows[0].onDemandAttributedCents, 250)
        expectEqual(rows[0].totalAttributedCents, 350)
        expect(rows[0].requestsCostsSum > 0, "requestsCosts preserved")
        expectEqual(rows[1].model, "gpt-5")

        let labels = formatModelAggregateLines(rows).joined(separator: "\n")
        expect(labels.localizedCaseInsensitiveContains("unofficial"), "attribution disclaimer")
        expect(labels.localizedCaseInsensitiveContains("invoice"), "not an invoice")
        expect(!labels.contains("eyJ"), "no jwt in model lines")
    } else {
        failures += 1
        fputs("FAIL: event parse\n", stderr)
    }
}

// MARK: - billing cycle filter

do {
    let start = Date(timeIntervalSince1970: 1_000)
    let end = Date(timeIntervalSince1970: 2_000)
    let inside = UsageEvent(
        model: "m",
        kind: "INCLUDED",
        timestamp: Date(timeIntervalSince1970: 1_500),
        chargedCents: 1
    )
    let outside = UsageEvent(
        model: "m",
        kind: "INCLUDED",
        timestamp: Date(timeIntervalSince1970: 3_000),
        chargedCents: 1
    )
    let filtered = filterEventsToBillingCycle([inside, outside], start: start, end: end)
    expectEqual(filtered.count, 1, "filter to cycle")
}

// MARK: - pagination termination

expectEqual(
    nextUsageEventsPage(currentPage: 1, pageSize: 500, returnedCount: 500, maxPages: 40),
    .fetchNext(page: 2),
    "full page continues"
)
expectEqual(
    nextUsageEventsPage(currentPage: 2, pageSize: 500, returnedCount: 12, maxPages: 40),
    .stop(reason: "short-page"),
    "short page stops"
)
expectEqual(
    nextUsageEventsPage(currentPage: 3, pageSize: 500, returnedCount: 0, maxPages: 40),
    .stop(reason: "empty-page"),
    "empty stops"
)
expectEqual(
    nextUsageEventsPage(currentPage: 40, pageSize: 500, returnedCount: 500, maxPages: 40),
    .stop(reason: "max-pages"),
    "max pages stops"
)

// MARK: - response list parse

do {
    let response: [String: Any] = [
        "usageEventsDisplay": [
            [
                "model": "a",
                "kind": "INCLUDED",
                "chargedCents": 5,
                "timestamp": 1_785_000_000_000,
            ] as [String: Any],
        ],
    ]
    let events = parseUsageEventsResponse(response)
    expectEqual(events.count, 1, "parse usageEventsDisplay")
    expectEqual(events.first?.model, "a")
}

if failures > 0 {
    fputs("\(failures) test failure(s)\n", stderr)
    exit(1)
}

print("All CursorGaugeCoreTests passed.")
