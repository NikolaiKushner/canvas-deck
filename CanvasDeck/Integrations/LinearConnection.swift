import AppKit
import Combine
import Trackers

/// Signing in to Linear and staying signed in, through Linear's MCP server
/// and OAuth: the browser opens Linear's own page, the user authorizes, and
/// the tokens live in the Keychain. No API key to copy, and nothing of
/// Claude Code's own Linear connection is touched: the app is a client of
/// its own. Settings → Linear.
@MainActor
final class LinearConnection: ObservableObject {
    static let shared = LinearConnection()

    enum State: Equatable {
        case signedOut
        case signingIn
        case connected(LinearUser)
        case failed(String)
    }

    @Published private(set) var state: State = .signedOut
    let sync: IssueSync
    private(set) var linear: LinearMCP!
    private let credentials = Credentials()
    private var redirect: LoopbackRedirect?

    /// Read for the stickers, write for "Move to…" and the sprint (step 12),
    /// which only ever run from the sticker's menu.
    static let scope = "read write"

    private init() {
        let credentials = self.credentials
        let client = MCPClient(endpoint: LinearMCP.endpoint) { try await credentials.accessToken() }
        let linear = LinearMCP(client: client)
        self.linear = linear
        sync = IssueSync(linear: linear, client: client)
        sync.onUnauthorized = { [weak self] in self?.lostSignIn() }
        Task { await restore() }
    }

    private func restore() async {
        guard await credentials.load() else { return }
        do {
            state = .connected(try await linear.me())
            sync.start()
        } catch MCPClient.Failure.unauthorized {
            lostSignIn()
        } catch {
            // Offline at launch: the cache still shows the issues; retry with the sync.
            if let user = await credentials.user { state = .connected(user) }
            sync.start()
        }
    }

    func signIn() {
        guard state != .signingIn else { return }
        state = .signingIn
        Task {
            do {
                let metadata = try await OAuth.metadata(for: LinearMCP.server)
                guard let registration = metadata.registrationEndpoint else { throw OAuth.Failure.malformed("no client registration") }
                let redirect = try LoopbackRedirect()
                self.redirect = redirect
                let redirectURL = try await redirect.start()
                let clientID = try await OAuth.register(at: registration, name: "Canvas Deck", redirect: redirectURL)
                let pkce = OAuth.PKCE()
                let expectedState = OAuth.randomState()
                let url = OAuth.authorizationURL(metadata, clientID: clientID, redirect: redirectURL, scope: Self.scope,
                                                 state: expectedState, pkce: pkce, resource: LinearMCP.endpoint)
                NSWorkspace.shared.open(url)
                let query = try await redirect.callback(timeout: 5 * 60)
                self.redirect = nil
                NSApp.activate()
                if let error = query["error"] { throw OAuth.Failure.denied(query["error_description"] ?? error) }
                guard query["state"] == expectedState, let code = query["code"] else { throw OAuth.Failure.denied("the answer did not match this sign-in") }
                let tokens = try await OAuth.exchange(code: code, metadata: metadata, clientID: clientID, redirect: redirectURL,
                                                      pkce: pkce, resource: LinearMCP.endpoint)
                await credentials.save(.init(clientID: clientID, tokenEndpoint: metadata.tokenEndpoint,
                                             revocationEndpoint: metadata.revocationEndpoint, tokens: tokens, user: nil))
                await sync.resetSession()
                let user = try await linear.me()
                await credentials.remember(user)
                state = .connected(user)
                sync.start()
            } catch is CancellationError {
                state = .signedOut
            } catch {
                redirect?.stop()
                redirect = nil
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancelSignIn() {
        redirect?.stop()
        redirect = nil
        state = .signedOut
    }

    func signOut() {
        sync.stop(clearing: true)
        state = .signedOut
        Task { await credentials.clear(revoking: true) }
    }

    /// The server no longer takes the tokens (revoked, or refresh failed).
    private func lostSignIn() {
        sync.stop(clearing: false)
        state = .failed("Linear signed this app out. Sign in again to keep the issues current.")
        Task { await credentials.clear(revoking: false) }
    }
}

/// The tokens, behind an actor so one refresh serves concurrent requests.
actor Credentials {
    struct Stored: Codable {
        var clientID: String
        var tokenEndpoint: URL
        var revocationEndpoint: URL?
        var tokens: OAuth.Tokens
        var user: LinearUser?
    }

    private static let service = "app.canvasdeck.linear"
    private static let account = "mcp"
    private var stored: Stored?
    private var refreshing: Task<OAuth.Tokens, Error>?

    var user: LinearUser? { stored?.user }

    func load() -> Bool {
        guard let data = Keychain.read(service: Self.service, account: Self.account),
              let decoded = try? JSONDecoder().decode(Stored.self, from: data) else { return false }
        stored = decoded
        return true
    }

    func save(_ value: Stored) {
        stored = value
        if let data = try? JSONEncoder().encode(value) { Keychain.write(data, service: Self.service, account: Self.account) }
    }

    func remember(_ user: LinearUser) {
        guard var value = stored else { return }
        value.user = user
        save(value)
    }

    func clear(revoking: Bool) async {
        if revoking, let value = stored, let endpoint = value.revocationEndpoint {
            await OAuth.revoke(value.tokens.refreshToken ?? value.tokens.accessToken, at: endpoint, clientID: value.clientID)
        }
        stored = nil
        Keychain.delete(service: Self.service, account: Self.account)
    }

    func accessToken() async throws -> String {
        guard let value = stored else { throw MCPClient.Failure.unauthorized }
        guard value.tokens.isExpired() else { return value.tokens.accessToken }
        if let refreshing { return try await refreshing.value.accessToken }
        let task = Task {
            try await OAuth.refresh(value.tokens, tokenEndpoint: value.tokenEndpoint, clientID: value.clientID, resource: LinearMCP.endpoint)
        }
        refreshing = task
        defer { refreshing = nil }
        do {
            let fresh = try await task.value
            var updated = value
            updated.tokens = fresh
            save(updated)
            return fresh.accessToken
        } catch {
            throw MCPClient.Failure.unauthorized
        }
    }
}
