import Foundation
import Testing
@testable import CanvasCore

@Suite struct AgentStatusTests {
    let t0 = Date(timeIntervalSince1970: 1_000)

    private func run(_ events: [AgentEvent], from start: AgentStatus = .initial) -> AgentStatus {
        var status = start
        for (offset, event) in events.enumerated() {
            status = status.applying(event, at: t0.addingTimeInterval(Double(offset)))
        }
        return status
    }

    @Test func claudeTurnGoesWorkingWaitingWorkingDone() {
        var status = AgentStatus.initial.applying(.sessionStarted, at: t0)
        #expect(status.state == .idle && status.hooked)
        status = status.applying(.promptSubmitted, at: t0 + 1)
        #expect(status.state == .working)
        status = status.applying(.permissionRequested(tool: "Bash"), at: t0 + 2)
        #expect(status.state == .waiting && status.reason == .permission && status.detail == "Bash")
        #expect(status.label == "Permission: Bash")
        status = status.applying(.toolFinished, at: t0 + 3)
        #expect(status.state == .working && status.reason == nil && status.detail == nil)
        status = status.applying(.stopped, at: t0 + 4)
        #expect(status.state == .done && status.label == "Done")
    }

    @Test func permissionNotificationKeepsTheToolFromPermissionRequest() {
        let status = run([
            .promptSubmitted,
            .permissionRequested(tool: "Edit"),
            .needsAttention(.permission, message: "Claude needs your permission"),
        ])
        #expect(status.reason == .permission && status.detail == "Edit")
    }

    @Test func toolNameComesFromTheMessageWhenNoRequestArrived() {
        let status = run([.promptSubmitted, .needsAttention(.permission, message: "Claude needs your permission to use Bash")])
        #expect(status.detail == "Bash")
    }

    @Test func questionAndPermissionAreDistinct() {
        let question = run([.promptSubmitted, .needsAttention(.question, message: "Pick one")])
        #expect(question.reason == .question && question.label == "Asking a question")
        let permission = run([.promptSubmitted, .permissionRequested(tool: nil)])
        #expect(permission.reason == .permission && permission.label == "Needs permission")
    }

    @Test func staleHookEventIsDropped() {
        let current = AgentStatus.initial.applying(.toolFinished, at: t0 + 5)
        let late = current.applying(.permissionRequested(tool: "Bash"), at: t0 + 4)
        #expect(late == current)
    }

    @Test func keystrokeOnPermissionMeansWorking() {
        let waiting = run([.promptSubmitted, .permissionRequested(tool: "Bash")])
        let answered = waiting.applying(.userInput, at: t0 + 10)
        #expect(answered.state == .working && answered.hooked)
    }

    @Test func keystrokeDoesNotAnswerAQuestion() {
        let asking = run([.promptSubmitted, .needsAttention(.question, message: nil)])
        #expect(asking.applying(.userInput, at: t0 + 10) == asking)
    }

    @Test func bellIsIgnoredWhileHooked() {
        let working = run([.sessionStarted, .promptSubmitted])
        #expect(working.applying(.bell, at: t0 + 10) == working)
        #expect(working.applying(.terminalNotification(title: "x", body: "y"), at: t0 + 10) == working)
    }

    @Test func bellWithoutHooksWaitsUntilTheUserTypes() {
        let rung = AgentStatus.initial.applying(.bell, at: t0)
        #expect(rung.state == .waiting && rung.reason == .input && !rung.hooked)
        let cleared = rung.applying(.userInput, at: t0 + 1)
        #expect(cleared.state == .idle)
    }

    @Test func terminalNotificationUsesBodyThenTitle() {
        let withBody = AgentStatus.initial.applying(.terminalNotification(title: "Build", body: "done"), at: t0)
        #expect(withBody.detail == "done")
        let titleOnly = AgentStatus.initial.applying(.terminalNotification(title: "Build", body: ""), at: t0)
        #expect(titleOnly.detail == "Build")
    }

    @Test func sessionEndReleasesTheCardToTerminalSignals() {
        let ended = run([.sessionStarted, .promptSubmitted, .sessionEnded])
        #expect(ended.state == .idle && !ended.hooked)
        #expect(ended.applying(.bell, at: t0 + 10).state == .waiting)
    }

    @Test func stopFailureIsAnError() {
        let failed = run([.promptSubmitted, .failed(message: "rate limit")])
        #expect(failed.state == .error && failed.detail == "rate limit" && failed.label == "Error")
    }

    @Test func hookMapping() {
        #expect(AgentEvent.fromHook(event: "UserPromptSubmit") == .promptSubmitted)
        #expect(AgentEvent.fromHook(event: "PermissionRequest", toolName: "Bash") == .permissionRequested(tool: "Bash"))
        #expect(AgentEvent.fromHook(event: "Notification", notificationType: "permission_prompt", message: "m") == .needsAttention(.permission, message: "m"))
        #expect(AgentEvent.fromHook(event: "Notification", notificationType: "idle_prompt") == .needsAttention(.input, message: nil))
        #expect(AgentEvent.fromHook(event: "Notification", notificationType: "elicitation_dialog") == .needsAttention(.question, message: nil))
        #expect(AgentEvent.fromHook(event: "Notification", notificationType: "auth_success") == nil)
        #expect(AgentEvent.fromHook(event: "Notification", message: "Claude needs your permission to use Bash") == .needsAttention(.permission, message: "Claude needs your permission to use Bash"))
        #expect(AgentEvent.fromHook(event: "StopFailure", message: "x") == .failed(message: "x"))
        #expect(AgentEvent.fromHook(event: "PreCompact") == nil)
    }

    @Test func statusRoundTripsThroughJSON() throws {
        let status = run([.promptSubmitted, .permissionRequested(tool: "Bash")])
        let decoded = try JSONDecoder().decode(AgentStatus.self, from: JSONEncoder().encode(status))
        #expect(decoded == status)
    }
}

@Suite struct OSCNotificationSnifferTests {
    private func sniff(_ chunks: [String]) -> [TerminalNotice] {
        var sniffer = OSCNotificationSniffer()
        return chunks.flatMap { sniffer.feed(ArraySlice(Array($0.utf8))) }
    }

    @Test func osc777WithBel() {
        #expect(sniff(["hi \u{1B}]777;notify;Build;done\u{07} bye"]) == [TerminalNotice(title: "Build", body: "done")])
    }

    @Test func osc777WithStringTerminatorAndSemicolonsInBody() {
        #expect(sniff(["\u{1B}]777;notify;T;a;b\u{1B}\\"]) == [TerminalNotice(title: "T", body: "a;b")])
    }

    @Test func osc9PlainText() {
        #expect(sniff(["\u{1B}]9;Tests passed\u{07}"]) == [TerminalNotice(title: "", body: "Tests passed")])
    }

    @Test func osc9ProgressIsIgnored() {
        #expect(sniff(["\u{1B}]9;4;1;50\u{07}"]).isEmpty)
    }

    @Test func sequenceSplitAcrossReads() {
        #expect(sniff(["abc\u{1B}", "]777;noti", "fy;X;Y", "\u{07}"]) == [TerminalNotice(title: "X", body: "Y")])
    }

    @Test func otherOSCAndCSIAreIgnored() {
        #expect(sniff(["\u{1B}]0;title\u{07}\u{1B}[31mred\u{1B}]7;file:///tmp\u{07}"]).isEmpty)
    }

    @Test func twoNoticesInOneRead() {
        let found = sniff(["\u{1B}]9;one\u{07}x\u{1B}]9;two\u{07}"])
        #expect(found.map(\.body) == ["one", "two"])
    }
}
