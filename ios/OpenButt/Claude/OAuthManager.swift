import Foundation

enum OAuthManager {

    // MARK: - Models

    struct OAuthCredentials: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Int64
        var scopes: [String]
        var subscriptionType: String?
        var rateLimitTier: String?
    }

    struct CredentialsFile: Codable {
        var claudeAiOauth: OAuthCredentials
    }

    struct TokenResponse: Codable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int
        let scope: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case scope
        }
    }

    // MARK: - Constants

    static let tokenURL = "https://platform.claude.com/v1/oauth/token"
    static let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e" // CLAUDE CHECK 
    static let scopes = "user:profile user:inference user:sessions:claude_code user:mcp_servers"
    static let credentialsPath = "~/.claude/.credentials.json"

    // MARK: - Public API

    /// Full flow: read → check → refresh if needed → write back
    static func ensureValidToken(ssh: SSHConnectionManager) async throws {
        let creds = try await readCredentials(ssh: ssh)
        guard isExpired(creds) else {
            buttLog.info("[oauth] token still valid, expires in \(timeRemaining(creds))s")
            return
        }
        buttLog.info("[oauth] token expired or expiring soon, refreshing...")
        let refreshed = try await refresh(creds)
        try await writeCredentials(refreshed, ssh: ssh)
        buttLog.info("[oauth] token refreshed, new expiry in \(timeRemaining(refreshed))s")
    }

    /// Force refresh regardless of expiry (use after a 401)
    static func forceRefresh(ssh: SSHConnectionManager) async throws {
        let creds = try await readCredentials(ssh: ssh)
        buttLog.info("[oauth] force refreshing token...")
        let refreshed = try await refresh(creds)
        try await writeCredentials(refreshed, ssh: ssh)
        buttLog.info("[oauth] force refreshed, new expiry in \(timeRemaining(refreshed))s")
    }

    // MARK: - Internal

    static func readCredentials(ssh: SSHConnectionManager) async throws -> OAuthCredentials {
        let output = try await ssh.executeCommand("cat \(credentialsPath)")
        guard let data = output.data(using: .utf8) else {
            throw OAuthError.invalidCredentialsFile
        }
        let file = try JSONDecoder().decode(CredentialsFile.self, from: data)
        return file.claudeAiOauth
    }

    static func isExpired(_ creds: OAuthCredentials, buffer: TimeInterval = 300) -> Bool {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let bufferMs = Int64(buffer * 1000)
        return creds.expiresAt < (nowMs + bufferMs)
    }

    static func refresh(_ creds: OAuthCredentials) async throws -> OAuthCredentials {
        guard let url = URL(string: tokenURL) else {
            throw OAuthError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": creds.refreshToken,
            "client_id": clientId,
            "scope": scopes
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OAuthError.refreshFailed("Invalid response")
        }
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OAuthError.refreshFailed("HTTP \(httpResponse.statusCode): \(body)")
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        return OAuthCredentials(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            expiresAt: nowMs + Int64(tokenResponse.expiresIn) * 1000,
            scopes: tokenResponse.scope.components(separatedBy: " "),
            subscriptionType: creds.subscriptionType,
            rateLimitTier: creds.rateLimitTier
        )
    }

    static func writeCredentials(_ creds: OAuthCredentials, ssh: SSHConnectionManager) async throws {
        // Re-read the full file to preserve other keys
        let rawOutput = try await ssh.executeCommand("cat \(credentialsPath)")
        guard let rawData = rawOutput.data(using: .utf8),
              var fileObj = try JSONSerialization.jsonObject(with: rawData) as? [String: Any] else {
            throw OAuthError.invalidCredentialsFile
        }

        // Update the claudeAiOauth section
        let credsData = try JSONEncoder().encode(creds)
        guard let credsObj = try JSONSerialization.jsonObject(with: credsData) as? [String: Any] else {
            throw OAuthError.invalidCredentialsFile
        }
        fileObj["claudeAiOauth"] = credsObj

        // Pretty-print for readability
        let updatedData = try JSONSerialization.data(withJSONObject: fileObj, options: [.prettyPrinted, .sortedKeys])
        guard let json = String(data: updatedData, encoding: .utf8) else {
            throw OAuthError.invalidCredentialsFile
        }

        // Write back via heredoc
        let escaped = json.replacingOccurrences(of: "'", with: "'\\''")
        try await ssh.executeCommand("cat > \(credentialsPath) << 'OBEOF'\n\(escaped)\nOBEOF")
    }

    // MARK: - Helpers

    private static func timeRemaining(_ creds: OAuthCredentials) -> Int {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        return max(0, Int((creds.expiresAt - nowMs) / 1000))
    }
}

// MARK: - Errors

enum OAuthError: LocalizedError {
    case invalidCredentialsFile
    case invalidURL
    case refreshFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredentialsFile:
            return "Could not read OAuth credentials from server"
        case .invalidURL:
            return "Invalid token endpoint URL"
        case .refreshFailed(let detail):
            return "Token refresh failed: \(detail)"
        }
    }
}
