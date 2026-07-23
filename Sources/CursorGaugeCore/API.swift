import Foundation

/// Official Cursor Connect RPC origin.
public let cursorAPIOrigin = "https://api2.cursor.sh"
/// Official Cursor web origin (dashboard cookie requests only).
public let cursorWebOrigin = "https://cursor.com"
public let dashboardUsageURL = URL(string: "https://cursor.com/dashboard/usage")!

private let periodUsagePath = "/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
private let authUsagePath = "/auth/usage"
private let usageSummaryPath = "/api/usage-summary"
private let filteredUsageEventsPath = "/api/dashboard/get-filtered-usage-events"

public let defaultUsageEventsPageSize = 500
public let defaultUsageEventsMaxPages = 40

public enum ApiFetchResult: Sendable {
    case ok(PeriodUsage)
    case failed(error: String, status: Int?)
}

public enum EventsFetchResult: Sendable {
    case ok([ModelUsageAggregate])
    case failed(error: String, status: Int?)
}

private enum APIError: Error {
    case blocked(String)
    case invalidJSON(status: Int)
    case timeout
    case transport(String)
    case authMissing
}

private func assertAllowedConnectURL(_ url: URL) throws {
    guard let scheme = url.scheme?.lowercased(), scheme == "https" else {
        throw APIError.blocked("Only HTTPS Cursor API URLs are allowed.")
    }
    guard let host = url.host?.lowercased(), host == "api2.cursor.sh" else {
        throw APIError.blocked("Request blocked: host is not the official Cursor API origin.")
    }
}

private func assertAllowedDashboardURL(_ url: URL) throws {
    guard let scheme = url.scheme?.lowercased(), scheme == "https" else {
        throw APIError.blocked("Only HTTPS Cursor dashboard URLs are allowed.")
    }
    guard let host = url.host?.lowercased(), host == "cursor.com" else {
        throw APIError.blocked("Request blocked: host is not cursor.com.")
    }
    let path = url.path
    guard path == usageSummaryPath || path == filteredUsageEventsPath else {
        throw APIError.blocked("Request blocked: dashboard path is not allowlisted.")
    }
}

private func sanitizeErrorMessage(_ message: String) -> String {
    message.replacingOccurrences(
        of: #"Bearer\s+\S+"#,
        with: "Bearer [redacted]",
        options: .regularExpression
    )
}

private actor URLSessionHolder {
    static let shared = URLSessionHolder()
    let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        session = URLSession(configuration: config)
    }
}

private func connectJSON(
    method: String,
    path: String,
    token: String,
    body: Data?
) async throws -> (status: Int, json: Any?) {
    guard var components = URLComponents(string: cursorAPIOrigin) else {
        throw APIError.blocked("Invalid Cursor API origin.")
    }
    components.path = path
    guard let url = components.url else {
        throw APIError.blocked("Invalid Cursor API URL.")
    }
    try assertAllowedConnectURL(url)

    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
    request.httpBody = body

    return try await performJSONRequest(request)
}

private func dashboardJSON(
    method: String,
    path: String,
    cookieValue: String,
    body: Data?
) async throws -> (status: Int, json: Any?) {
    guard var components = URLComponents(string: cursorWebOrigin) else {
        throw APIError.blocked("Invalid Cursor web origin.")
    }
    components.path = path
    guard let url = components.url else {
        throw APIError.blocked("Invalid Cursor dashboard URL.")
    }
    try assertAllowedDashboardURL(url)

    var request = URLRequest(url: url)
    request.httpMethod = method
    // Attach only the locally constructed session cookie; never persist cookies.
    request.setValue("WorkosCursorSessionToken=\(cookieValue)", forHTTPHeaderField: "Cookie")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if method.uppercased() == "POST" {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cursorWebOrigin, forHTTPHeaderField: "Origin")
    }
    request.httpBody = body
    request.httpShouldHandleCookies = false

    return try await performJSONRequest(request)
}

private func performJSONRequest(_ request: URLRequest) async throws -> (status: Int, json: Any?) {
    let (data, response): (Data, URLResponse)
    do {
        (data, response) = try await URLSessionHolder.shared.session.data(for: request)
    } catch let urlError as URLError where urlError.code == .timedOut {
        throw APIError.timeout
    } catch {
        throw APIError.transport(sanitizeErrorMessage(error.localizedDescription))
    }

    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if data.isEmpty {
        return (status, nil)
    }
    do {
        let json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return (status, json)
    } catch {
        // Never attach raw body — may contain sensitive fields.
        throw APIError.invalidJSON(status: status)
    }
}

private func mapAPIError(_ err: APIError) -> (String, Int?) {
    switch err {
    case .blocked(let message):
        return (message, nil)
    case .invalidJSON(let status):
        return ("Invalid JSON from Cursor API (HTTP \(status)).", status)
    case .timeout:
        return ("Cursor API request timed out.", nil)
    case .transport(let message):
        return (message, nil)
    case .authMissing:
        return ("Could not build dashboard session from local Cursor login.", nil)
    }
}

/**
 Fetch current-period usage from Cursor-owned Connect endpoints.
 Token is used only as Authorization bearer; never logged.
 */
public func fetchPeriodUsage(token: String) async -> ApiFetchResult {
    do {
        let periodBody = Data("{}".utf8)
        let period = try await connectJSON(
            method: "POST",
            path: periodUsagePath,
            token: token,
            body: periodBody
        )
        if period.status == 401 || period.status == 403 {
            return .failed(
                error: "Cursor session rejected by API (sign in again in Cursor).",
                status: period.status
            )
        }
        if (200..<300).contains(period.status), let usage = parsePeriodUsageResponse(period.json) {
            return .ok(usage)
        }

        let authUsage = try await connectJSON(
            method: "GET",
            path: authUsagePath,
            token: token,
            body: nil
        )
        if authUsage.status == 401 || authUsage.status == 403 {
            return .failed(
                error: "Cursor session rejected by API (sign in again in Cursor).",
                status: authUsage.status
            )
        }
        if (200..<300).contains(authUsage.status),
           let usage = parsePeriodUsageResponse(authUsage.json)
        {
            return .ok(usage)
        }

        return .failed(
            error: "Usage payload shape not recognized (Cursor API may have changed).",
            status: period.status != 0 ? period.status : authUsage.status
        )
    } catch let err as APIError {
        let mapped = mapAPIError(err)
        return .failed(error: mapped.0, status: mapped.1)
    } catch {
        return .failed(error: sanitizeErrorMessage(error.localizedDescription), status: nil)
    }
}

/**
 Optional dashboard usage-summary (allowlisted). Not required for Overview when
 GetCurrentPeriodUsage succeeds; exposed for completeness / future enrichment.
 */
public func fetchUsageSummary(token: String) async -> ApiFetchResult {
    do {
        guard let cookie = makeDashboardSessionCookieValue(token: token) else {
            throw APIError.authMissing
        }
        let result = try await dashboardJSON(
            method: "GET",
            path: usageSummaryPath,
            cookieValue: cookie,
            body: nil
        )
        if result.status == 401 || result.status == 403 {
            return .failed(
                error: "Cursor dashboard session rejected (sign in again in Cursor).",
                status: result.status
            )
        }
        if (200..<300).contains(result.status), let usage = parsePeriodUsageResponse(result.json) {
            return .ok(usage)
        }
        return .failed(
            error: "Usage summary shape not recognized (Cursor API may have changed).",
            status: result.status
        )
    } catch let err as APIError {
        let mapped = mapAPIError(err)
        return .failed(error: mapped.0, status: mapped.1)
    } catch {
        return .failed(error: sanitizeErrorMessage(error.localizedDescription), status: nil)
    }
}

/**
 Fetch and aggregate current-billing-cycle usage events by model.
 Paginates conservatively; never requests all-time history without bounds.
 */
public func fetchModelUsageAggregates(
    token: String,
    periodStart: Date?,
    periodEnd: Date?,
    pageSize: Int = defaultUsageEventsPageSize,
    maxPages: Int = defaultUsageEventsMaxPages
) async -> EventsFetchResult {
    do {
        guard let cookie = makeDashboardSessionCookieValue(token: token) else {
            throw APIError.authMissing
        }
        guard periodStart != nil || periodEnd != nil else {
            return .failed(
                error: "Billing cycle bounds unavailable; refusing unbounded event fetch.",
                status: nil
            )
        }

        var allEvents: [UsageEvent] = []
        var page = 1

        while page >= 1 {
            var bodyObject: [String: Any] = [
                "page": page,
                "pageSize": pageSize,
            ]
            if let start = periodStart {
                bodyObject["startDate"] = Int64(start.timeIntervalSince1970 * 1000)
            }
            if let end = periodEnd {
                bodyObject["endDate"] = Int64(end.timeIntervalSince1970 * 1000)
            }

            let body = try JSONSerialization.data(withJSONObject: bodyObject, options: [])
            let result = try await dashboardJSON(
                method: "POST",
                path: filteredUsageEventsPath,
                cookieValue: cookie,
                body: body
            )

            if result.status == 401 || result.status == 403 {
                return .failed(
                    error: "Cursor dashboard session rejected (sign in again in Cursor).",
                    status: result.status
                )
            }
            guard (200..<300).contains(result.status) else {
                return .failed(
                    error: "Usage events request failed (HTTP \(result.status)).",
                    status: result.status
                )
            }

            let pageEvents = parseUsageEventsResponse(result.json)
            allEvents.append(contentsOf: pageEvents)

            switch nextUsageEventsPage(
                currentPage: page,
                pageSize: pageSize,
                returnedCount: pageEvents.count,
                maxPages: maxPages
            ) {
            case .stop:
                let filtered = filterEventsToBillingCycle(
                    allEvents,
                    start: periodStart,
                    end: periodEnd
                )
                return .ok(aggregateUsageEventsByModel(filtered))
            case .fetchNext(let next):
                page = next
            }
        }

        return .failed(error: "Unexpected pagination exit.", status: nil)
    } catch let err as APIError {
        let mapped = mapAPIError(err)
        return .failed(error: mapped.0, status: mapped.1)
    } catch {
        return .failed(error: sanitizeErrorMessage(error.localizedDescription), status: nil)
    }
}
