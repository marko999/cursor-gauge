import Foundation

public enum AuthSource: String, Sendable {
    case stateVscdb = "state.vscdb"
    case keychain = "keychain"
}

public enum AuthDiscoveryResult: Sendable {
    case ok(source: AuthSource)
    case failed(reason: String)
}

private let accessKey = "cursorAuth/accessToken"
private let sqlite3Path = "/usr/bin/sqlite3"
private let securityPath = "/usr/bin/security"

/// macOS path to Cursor's global state DB (same store Cursor uses when signed in).
public func resolveCursorStateDbPath(
    home: String = NSHomeDirectory()
) -> String {
    (home as NSString).appendingPathComponent(
        "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    )
}

public func looksLikeJwt(_ value: String) -> Bool {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    return parts.count == 3 && parts.allSatisfy { !$0.isEmpty } && value.count > 40
}

/// Extract JWT `sub` from a compact JWS without logging the token or payload.
public func jwtSubject(from token: String) -> String? {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 3 else { return nil }
    var payload = parts[1]
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let pad = (4 - payload.count % 4) % 4
    if pad > 0 {
        payload += String(repeating: "=", count: pad)
    }
    guard let data = Data(base64Encoded: payload),
          let json = try? JSONSerialization.jsonObject(with: data),
          let record = json as? [String: Any]
    else {
        return nil
    }
    if let sub = record["sub"] as? String {
        let trimmed = sub.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    if let subNum = record["sub"] as? NSNumber {
        return subNum.stringValue
    }
    return nil
}

/**
 Build the WorkOS dashboard session cookie value (`URL-encoded sub::token`).
 Caller attaches it only as an in-memory Cookie header; never log or persist.
 */
public func makeDashboardSessionCookieValue(token: String) -> String? {
    guard looksLikeJwt(token), let sub = jwtSubject(from: token) else { return nil }
    let raw = "\(sub)::\(token)"
    // Match browser-style encodeURIComponent / quote(safe='') for the cookie value.
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return raw.addingPercentEncoding(withAllowedCharacters: allowed)
}

private func runProcess(
    executable: String,
    arguments: [String],
    timeoutSeconds: TimeInterval
) -> String? {
    guard FileManager.default.isExecutableFile(atPath: executable) else {
        return nil
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = ["PATH": "/usr/bin:/bin"]

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    do {
        try process.run()
    } catch {
        return nil
    }

    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while process.isRunning {
        if Date() > deadline {
            process.terminate()
            return nil
        }
        Thread.sleep(forTimeInterval: 0.05)
    }

    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    // Discard stderr without logging — may contain path/context noise.
    _ = stderr.fileHandleForReading.readDataToEndOfFile()

    guard process.terminationStatus == 0 else { return nil }
    let text = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return text
}

/// Read access token via system sqlite3 in read-only mode.
/// Prefer this over loading the DB into process memory — local state.vscdb can be multi-GiB.
func readTokenViaSqlite3(dbPath: String) -> String? {
    guard FileManager.default.fileExists(atPath: sqlite3Path),
          FileManager.default.fileExists(atPath: dbPath)
    else {
        return nil
    }

    // URI mode=ro avoids write locks when Cursor has the DB open.
    let uri = "file:\(dbPath)?mode=ro"
    let sql = "SELECT value FROM ItemTable WHERE key='\(accessKey)' LIMIT 1;"
    guard let token = runProcess(
        executable: sqlite3Path,
        arguments: [uri, sql],
        timeoutSeconds: 15
    ) else {
        return nil
    }
    return looksLikeJwt(token) ? token : nil
}

/// Fallback: Cursor also stores the access token in the login keychain on macOS.
func readTokenViaKeychain() -> String? {
    guard FileManager.default.fileExists(atPath: securityPath) else {
        return nil
    }
    guard let token = runProcess(
        executable: securityPath,
        arguments: [
            "find-generic-password",
            "-s", "cursor-access-token",
            "-a", "cursor-user",
            "-w",
        ],
        timeoutSeconds: 10
    ) else {
        return nil
    }
    return looksLikeJwt(token) ? token : nil
}

/**
 Discover the signed-in Cursor session token.
 Token is returned only for in-memory use by the caller for a single request.
 Never log, print, persist, or copy the token.
 */
public func discoverAccessToken() -> (token: String?, discovery: AuthDiscoveryResult) {
    #if !os(macOS)
    return (
        nil,
        .failed(reason: "This app supports macOS only.")
    )
    #else
    let dbPath = resolveCursorStateDbPath()
    if !FileManager.default.fileExists(atPath: dbPath) {
        if let keychain = readTokenViaKeychain() {
            return (keychain, .ok(source: .keychain))
        }
        return (
            nil,
            .failed(
                reason:
                    "Cursor state database not found. Sign in to Cursor on this Mac, then Refresh."
            )
        )
    }

    if let fromDb = readTokenViaSqlite3(dbPath: dbPath) {
        return (fromDb, .ok(source: .stateVscdb))
    }

    if let fromKeychain = readTokenViaKeychain() {
        return (fromKeychain, .ok(source: .keychain))
    }

    return (
        nil,
        .failed(
            reason:
                "No Cursor access token found. Sign in to Cursor (Settings → Account), then Refresh."
        )
    )
    #endif
}
