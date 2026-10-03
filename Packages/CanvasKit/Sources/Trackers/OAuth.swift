import CryptoKit
import Foundation

/// OAuth 2.1 for an MCP server, as a native app: discovery from the
/// server's metadata, dynamic client registration (no secret), PKCE, a
/// loopback redirect. Linear's MCP server works this way (checked
/// 2026-10-01: S256, `token_endpoint_auth_method: none`).
public enum OAuth {
    public struct ServerMetadata: Codable, Sendable {
        public var issuer: String?
        public var authorizationEndpoint: URL
        public var tokenEndpoint: URL
        public var registrationEndpoint: URL?
        public var revocationEndpoint: URL?

        enum CodingKeys: String, CodingKey {
            case issuer
            case authorizationEndpoint = "authorization_endpoint"
            case tokenEndpoint = "token_endpoint"
            case registrationEndpoint = "registration_endpoint"
            case revocationEndpoint = "revocation_endpoint"
        }
    }

    public struct Tokens: Codable, Equatable, Sendable {
        public var accessToken: String
        public var refreshToken: String?
        public var expiresAt: Date?
        public var scope: String?

        public init(accessToken: String, refreshToken: String?, expiresAt: Date?, scope: String?) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.expiresAt = expiresAt
            self.scope = scope
        }

        /// A minute early, so a request never starts with a token about to lapse.
        public func isExpired(at now: Date = Date()) -> Bool {
            expiresAt.map { $0.addingTimeInterval(-60) <= now } ?? false
        }
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case http(Int, String)
        case malformed(String)
        case denied(String)

        public var errorDescription: String? {
            switch self {
            case .http(let code, let body): "The server answered \(code)\(body.isEmpty ? "" : ": \(body.prefix(200))")"
            case .malformed(let what): "Unexpected answer: \(what)"
            case .denied(let why): "Sign-in was not completed: \(why)"
            }
        }
    }

    // MARK: PKCE

    public struct PKCE: Sendable {
        public let verifier: String
        public var challenge: String { Self.challenge(for: verifier) }

        public init(verifier: String = PKCE.randomVerifier()) {
            self.verifier = verifier
        }

        public static func randomVerifier() -> String {
            var bytes = [UInt8](repeating: 0, count: 48)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            return base64URL(Data(bytes))
        }

        public static func challenge(for verifier: String) -> String {
            base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        }
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func randomState() -> String { PKCE.randomVerifier() }

    // MARK: Requests

    public static func metadata(for server: URL, session: URLSession = .shared) async throws -> ServerMetadata {
        let url = server.appending(path: ".well-known/oauth-authorization-server")
        let (data, response) = try await session.data(from: url)
        try check(response, data)
        do { return try JSONDecoder().decode(ServerMetadata.self, from: data) } catch { throw Failure.malformed("server metadata") }
    }

    /// Registers this app for one sign-in: a client id for `redirect`.
    public static func register(at endpoint: URL, name: String, redirect: URL, session: URLSession = .shared) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": name,
            "redirect_uris": [redirect.absoluteString],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ])
        let (data, response) = try await session.data(for: request)
        try check(response, data)
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = object["client_id"] as? String else { throw Failure.malformed("client registration") }
        return id
    }

    public static func authorizationURL(_ metadata: ServerMetadata, clientID: String, redirect: URL, scope: String,
                                        state: String, pkce: PKCE, resource: URL) -> URL {
        var components = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect.absoluteString),
            .init(name: "scope", value: scope),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "resource", value: resource.absoluteString),
        ]
        return components.url!
    }

    public static func exchange(code: String, metadata: ServerMetadata, clientID: String, redirect: URL,
                                pkce: PKCE, resource: URL, session: URLSession = .shared) async throws -> Tokens {
        try await token(metadata.tokenEndpoint, form: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirect.absoluteString,
            "client_id": clientID,
            "code_verifier": pkce.verifier,
            "resource": resource.absoluteString,
        ], session: session)
    }

    public static func refresh(_ tokens: Tokens, tokenEndpoint: URL, clientID: String, resource: URL,
                               session: URLSession = .shared) async throws -> Tokens {
        guard let refresh = tokens.refreshToken else { throw Failure.denied("no refresh token") }
        var fresh = try await token(tokenEndpoint, form: [
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": clientID,
            "resource": resource.absoluteString,
        ], session: session)
        if fresh.refreshToken == nil { fresh.refreshToken = refresh }
        return fresh
    }

    /// RFC 7009: the server forgets the token.
    public static func revoke(_ token: String, at endpoint: URL, clientID: String, session: URLSession = .shared) async {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(["token": token, "client_id": clientID])
        _ = try? await session.data(for: request)
    }

    static func token(_ endpoint: URL, form: [String: String], session: URLSession) async throws -> Tokens {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formBody(form)
        let (data, response) = try await session.data(for: request)
        try check(response, data)
        return try decodeTokens(data, now: Date())
    }

    public static func decodeTokens(_ data: Data, now: Date) throws -> Tokens {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = object["access_token"] as? String else { throw Failure.malformed("token response") }
        let expires = (object["expires_in"] as? Double) ?? (object["expires_in"] as? Int).map(Double.init)
        return Tokens(accessToken: access, refreshToken: object["refresh_token"] as? String,
                      expiresAt: expires.map { now.addingTimeInterval($0) }, scope: object["scope"] as? String)
    }

    static func formBody(_ form: [String: String]) -> Data {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?/:")
        return Data(form.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&").utf8)
    }

    static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.http(http.statusCode, String(decoding: data.prefix(300), as: UTF8.self))
        }
    }
}
