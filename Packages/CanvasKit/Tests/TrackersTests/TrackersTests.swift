import Foundation
import Testing
@testable import Trackers

@Suite struct OAuthTests {
    @Test func pkceMatchesRFC7636() {
        // RFC 7636 appendix B.
        #expect(OAuth.PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let a = OAuth.PKCE(), b = OAuth.PKCE()
        #expect(a.verifier != b.verifier && a.verifier.count >= 43)
    }

    @Test func tokensExpireAMinuteEarly() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let tokens = try OAuth.decodeTokens(Data(#"{"access_token":"a","refresh_token":"r","expires_in":86100,"token_type":"Bearer"}"#.utf8), now: now)
        #expect(tokens.refreshToken == "r")
        #expect(!tokens.isExpired(at: now.addingTimeInterval(86000)))
        #expect(tokens.isExpired(at: now.addingTimeInterval(86050)))
    }

    @Test func authorizationURLCarriesPKCEAndResource() {
        let metadata = OAuth.ServerMetadata(issuer: nil, authorizationEndpoint: URL(string: "https://x.test/authorize")!, tokenEndpoint: URL(string: "https://x.test/token")!)
        let url = OAuth.authorizationURL(metadata, clientID: "c", redirect: URL(string: "http://127.0.0.1:5000/callback")!, scope: "read write",
                                         state: "s", pkce: .init(verifier: "v"), resource: URL(string: "https://x.test/mcp")!)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(items.first { $0.name == "code_challenge_method" }?.value == "S256")
        #expect(items.first { $0.name == "resource" }?.value == "https://x.test/mcp")
        #expect(items.first { $0.name == "scope" }?.value == "read write")
    }
}

@Suite struct MCPTests {
    @Test func readsJSONAndEventStream() throws {
        let json = Data(#"{"jsonrpc":"2.0","id":3,"result":{"ok":true}}"#.utf8)
        #expect(try MCPClient.message(id: 3, in: json, contentType: "application/json")?["result"] != nil)
        let stream = Data("event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\n\nevent: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":7,\n\n".utf8)
            + Data("event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"content\":[]}}\n\n".utf8)
        #expect(try MCPClient.message(id: 7, in: stream, contentType: "text/event-stream")?["result"] != nil)
        #expect(try MCPClient.message(id: 9, in: stream, contentType: "text/event-stream") == nil)
    }
}

@Suite struct LinearTests {
    // The shape `list_issues` answered with on 2026-10-01, values made up.
    let page = """
    {"issues":[{"id":"ABC-12","uuid":"1f0","title":"Fix the export","description":"Long text","priority":{"value":2,"name":"High"},
    "url":"https://linear.app/acme/issue/ABC-12/fix-the-export","gitBranchName":"abc-12-fix-the-export","createdAt":"2024-10-17T08:44:25.316Z",
    "updatedAt":"2026-10-01T13:05:15.962Z","archivedAt":null,"status":"In Review","statusType":"started","labels":["Bug"],
    "assignee":"Someone","team":"Core","teamId":"t1","cycleId":"c9","newFieldFromTheFuture":{"x":1}}],"hasNextPage":false,"cursor":null}
    """

    @Test func decodesIssuesLeniently() throws {
        let decoded = try LinearMCP.decode(LinearMCP.Page.self, from: page)
        let issue = try #require(decoded.issues.first)
        #expect(issue.id == "ABC-12" && issue.status == "In Review" && issue.isOpen)
        #expect(issue.priority?.value == 2 && issue.cycleId == "c9")
        #expect(issue.gitBranchName == "abc-12-fix-the-export")
        let expected = ISO8601DateFormatter().date(from: "2026-10-01T13:05:15Z")!.addingTimeInterval(0.962)
        #expect(abs(issue.updatedAt!.timeIntervalSince(expected)) < 0.001)
    }

    @Test func listsFromArrayOrObject() throws {
        let array = try LinearMCP.decodeList(IssueStatus.self, key: "statuses", from: ##"[{"id":"s1","name":"Todo","type":"unstarted","color":"#e2e2e2"}]"##)
        #expect(array.first?.color == "#e2e2e2")
        let object = try LinearMCP.decodeList(Cycle.self, key: "cycles", from: #"{"cycles":[{"id":"c9","number":42,"name":null}]}"#)
        #expect(object.first?.title == "Cycle 42")
        let other = try LinearMCP.decodeList(Cycle.self, key: "cycles", from: #"{"items":[{"id":"c1","name":"Sprint 7"}]}"#)
        #expect(other.first?.title == "Sprint 7")
    }

    @Test func cycleAndNotificationsAsTheServerSendsThem() throws {
        // Shapes from 2026-10-01, values made up.
        let cycles = try LinearMCP.decodeList(Cycle.self, key: "cycles", from: #"[{"id":"c1","title":"Sprint 42","number":19,"startsAt":"2026-09-29T21:00:00.000Z","isCurrent":true}]"#)
        #expect(cycles.first?.title == "Sprint 42")
        let inbox = try LinearMCP.decodeList(LinearNotification.self, key: "notifications", from: #"{"notifications":[{"id":"n1","type":"issueNewComment","title":"Fix it","subtitle":"Ann commented: done","url":"https://linear.app/x/issue/A-1#comment-1","createdAt":"2026-10-01T13:34:08.463Z","readAt":null}]}"#)
        #expect(inbox.first?.type == "issueNewComment" && inbox.first?.readAt == nil)
    }

    @Test func nullableSchemaProperty() {
        #expect(LinearMCP.acceptsNull(property: "cycle", in: Data(#"{"properties":{"cycle":{"type":["string","null"]}}}"#.utf8)))
        #expect(LinearMCP.acceptsNull(property: "cycle", in: Data(#"{"properties":{"cycle":{"anyOf":[{"type":"string"},{"type":"null"}]}}}"#.utf8)))
        #expect(!LinearMCP.acceptsNull(property: "cycle", in: Data(#"{"properties":{"cycle":{"type":"string"}}}"#.utf8)))
    }
}
