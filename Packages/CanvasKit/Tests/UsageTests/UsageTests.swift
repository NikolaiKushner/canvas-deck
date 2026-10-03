import Foundation
import Testing
@testable import Usage

@Suite struct StatuslineTests {
    let now = Date(timeIntervalSince1970: 1_738_400_000)

    /// The example payload from the Claude Code status line docs.
    let docsExample = Data("""
    {"session_id":"abc123","model":{"id":"claude-opus-4-7","display_name":"Opus"},
     "cost":{"total_cost_usd":0.01234,"total_lines_added":156,"total_lines_removed":23},
     "context_window":{"used_percentage":8},
     "rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1738425600},
                    "seven_day":{"used_percentage":41.2,"resets_at":1738857600}}}
    """.utf8)

    @Test func decodesTheDocsExample() throws {
        let payload = try #require(StatuslinePayload.decode(docsExample))
        #expect(payload.sessionID == "abc123")
        #expect(payload.cost?.totalCostUSD == 0.01234)
        #expect(payload.rateLimits?.fiveHour?.usedPercentage == 23.5)
        #expect(payload.rateLimits?.sevenDay?.resetsAt == 1_738_857_600)
        #expect(payload.linesChanged == 179)
    }

    @Test func rendersInTheNomnomtokensFormatWeeklyFirst() throws {
        let payload = try #require(StatuslinePayload.decode(docsExample))
        // 5h resets in 7h06m40s → 7h6m; 7d in 5d6h... → 5d6h
        #expect(StatuslineText.render(payload, now: now) == "(^_^)  $0.01  ctx 8%  7d 41% ·5d7h  5h 24% ·7h6m  179 lines")
    }

    @Test func fiveHourFirstWhenItIsTighter() {
        var payload = StatuslinePayload()
        payload.rateLimits = .init(fiveHour: .init(usedPercentage: 73, resetsAt: nil), sevenDay: .init(usedPercentage: 20, resetsAt: nil))
        #expect(StatuslineText.render(payload, now: now) == "(＾ｕ＾)  5h 73%  7d 20%")
    }

    @Test func emptyPayloadIsJustTheFace() {
        #expect(StatuslineText.render(StatuslinePayload(), now: now) == "(・_・)")
    }

    @Test func untilResetRoundsTheLeadingUnitDown() {
        #expect(StatuslineText.untilReset(now.addingTimeInterval(30), now: now) == "1m")
        #expect(StatuslineText.untilReset(now.addingTimeInterval(59 * 60 + 59), now: now) == "59m")
        #expect(StatuslineText.untilReset(now.addingTimeInterval(2 * 3600), now: now) == "2h")
        #expect(StatuslineText.untilReset(now.addingTimeInterval(107 * 60), now: now) == "1h47m")
        #expect(StatuslineText.untilReset(now.addingTimeInterval(99 * 3600), now: now) == "4d3h")
        #expect(StatuslineText.untilReset(now.addingTimeInterval(-5), now: now) == "now")
    }

    @Test func usdFormatting() {
        #expect(StatuslineText.usd(0) == "$0.00")
        #expect(StatuslineText.usd(0.004) == "$0.0040")
        #expect(StatuslineText.usd(4.2) == "$4.20")
    }

    @Test func moodThresholds() {
        #expect(Mood(usedPercentage: 4.9) == .hungry)
        #expect(Mood(usedPercentage: 49) == .content)
        #expect(Mood(usedPercentage: 79) == .full)
        #expect(Mood(usedPercentage: 99) == .stuffed)
        #expect(Mood(usedPercentage: 100) == .overstuffed)
    }
}

@Suite struct LimitForecastTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func sample(_ pct: Double, hours: Double, resets: Double = 10) -> LimitSample {
        LimitSample(window: LimitKey.fiveHour, usedPercentage: pct, resetsAt: t0.addingTimeInterval(resets * 3600), at: t0.addingTimeInterval(hours * 3600))
    }

    @Test func steadyBurnProjectsTheFullTime() throws {
        let now = t0.addingTimeInterval(2 * 3600)
        let forecast = try #require(LimitForecast.make([sample(20, hours: 0), sample(30, hours: 1), sample(40, hours: 2)], now: now))
        #expect(abs(forecast.burnPerHour - 10) < 1e-9)
        #expect(forecast.fullAt == now.addingTimeInterval(6 * 3600))
        #expect(forecast.fillsBeforeReset) // full at 8h, reset at 10h
    }

    @Test func resetStartsANewCycle() {
        let cycle = LimitForecast.currentCycle([sample(80, hours: 0), sample(95, hours: 1), sample(5, hours: 2), sample(12, hours: 3)])
        #expect(cycle.map(\.usedPercentage) == [5, 12])
    }

    @Test func flatUsageNeverFills() throws {
        let forecast = try #require(LimitForecast.make([sample(40, hours: 0), sample(40, hours: 1)], now: t0))
        #expect(forecast.burnPerHour == 0 && forecast.fullAt == nil && !forecast.fillsBeforeReset)
    }

    @Test func oneSampleHasNoRate() throws {
        let forecast = try #require(LimitForecast.make([sample(40, hours: 0)], now: t0))
        #expect(forecast.samples == 1 && forecast.fullAt == nil)
    }

    @Test func unknownWindowsAreKeptAndNamed() throws {
        let json = Data(#"{"rate_limits":{"five_hour":{"used_percentage":44,"resets_at":1},"seven_day":{"used_percentage":9},"seven_day_fable":{"used_percentage":12,"resets_at":2},"spend_limit":{"used_percentage":37.6},"note":"x","odd":{"foo":1}}}"#.utf8)
        let payload = try #require(StatuslinePayload.decode(json))
        let keys = LimitKey.sorted(payload.rateLimits?.windows.keys ?? [:].keys)
        #expect(keys == ["five_hour", "seven_day", "seven_day_fable", "spend_limit"])
        #expect(keys.map(LimitKey.title) == ["5-hour limit", "Weekly · all models", "Weekly · Fable", "Spend limit"])
        #expect(LimitSample.from(payload, at: t0).count == 4)
    }

    @Test func samplesFromPayload() {
        var payload = StatuslinePayload()
        payload.rateLimits = .init(fiveHour: .init(usedPercentage: 12, resetsAt: 2_000_000), sevenDay: nil)
        let samples = LimitSample.from(payload, at: t0)
        #expect(samples == [LimitSample(window: LimitKey.fiveHour, usedPercentage: 12, resetsAt: Date(timeIntervalSince1970: 2_000_000), at: t0)])
    }
}

@Suite struct TranscriptTests {
    @Test func pricingKeys() {
        #expect(ModelPricing.key(for: "claude-haiku-4-5-20251001") == "claude-haiku-4-5")
        #expect(ModelPricing.key(for: "claude-opus-5-5[1m]") == "claude-opus-5")
        #expect(ModelPricing.key(for: "claude-sonnet-5-5") == "claude-sonnet-5")
        #expect(ModelPricing.key(for: "claude-fable-5-1") == "claude-fable-5")
        #expect(ModelPricing.key(for: "<synthetic>") == nil)
        #expect(ModelPricing.key(for: "gpt-5") == nil)
    }

    @Test func costWithCacheMultipliers() throws {
        // Opus 5: $5 in, $25 out per million.
        let tokens = ModelPricing.Tokens(input: 1_000_000, output: 1_000_000, cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000, cacheRead: 1_000_000)
        let cost = try #require(ModelPricing.cost(model: "claude-opus-5-5", tokens: tokens))
        #expect(abs(cost - (5 + 25 + 6.25 + 10 + 0.5)) < 1e-9)
        #expect(ModelPricing.cost(model: "<synthetic>", tokens: tokens) == 0)
        #expect(ModelPricing.cost(model: "mystery-1", tokens: tokens) == nil)
    }

    @Test func duplicatedTurnsCountOnce() {
        let turn = #"{"type":"assistant","requestId":"r1","timestamp":"2026-09-30T10:00:00.000Z","message":{"id":"m1","model":"claude-haiku-4-5","usage":{"input_tokens":1000000,"output_tokens":0}}}"#
        let other = #"{"type":"assistant","requestId":"r2","timestamp":"2026-09-30T10:01:00.000Z","message":{"id":"m2","model":"claude-haiku-4-5","usage":{"input_tokens":0,"output_tokens":1000000,"cache_creation_input_tokens":0}}}"#
        let summary = TranscriptSummary.parse(Data([turn, turn, turn, other].joined(separator: "\n").utf8))
        #expect(summary.turns == 2)
        #expect(abs(summary.costUSD - 6) < 1e-9) // $1 input + $5 output
    }

    @Test func cacheCreationFallsBackToTheFlatTotal() {
        let line = #"{"type":"assistant","requestId":"r","message":{"id":"m","model":"claude-haiku-4-5","usage":{"cache_creation_input_tokens":1000000,"cache_creation":{"ephemeral_1h_input_tokens":400000}}}}"#
        let summary = TranscriptSummary.parse(Data(line.utf8))
        #expect(summary.tokens.cacheWrite1h == 400_000 && summary.tokens.cacheWrite5m == 600_000)
    }

    @Test func firstPromptSkipsCommandsAndToolResults() {
        let lines = [
            #"{"type":"user","message":{"content":"<command-name>/clear</command-name>"}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":"x"}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"text","text":"Fix the login bug"}]}}"#,
            #"{"type":"user","message":{"content":"second"}}"#,
            "not json",
        ]
        let summary = TranscriptSummary.parse(Data(lines.joined(separator: "\n").utf8))
        #expect(summary.firstPrompt == "Fix the login bug")
    }

    @Test func unknownModelIsCountedAsUnpriced() {
        let line = #"{"type":"assistant","requestId":"r","message":{"id":"m","model":"mystery","usage":{"input_tokens":10}}}"#
        let summary = TranscriptSummary.parse(Data(line.utf8))
        #expect(summary.unpricedTurns == 1 && summary.costUSD == 0)
    }
}

@Suite struct AccountTests {
    let home = "/Users/me"

    @Test func accountComesFromEnvironmentThenTranscript() {
        #expect(ClaudeConfigPath.of(environment: ["CLAUDE_CONFIG_DIR": "~/.claude-work/"], transcriptPath: nil, home: home) == "/Users/me/.claude-work")
        #expect(ClaudeConfigPath.of(environment: [:], transcriptPath: "/Users/me/.claude-personal/projects/-Users-me-dev-x/abc.jsonl", home: home) == "/Users/me/.claude-personal")
        #expect(ClaudeConfigPath.of(environment: ["CLAUDE_CONFIG_DIR": ""], transcriptPath: nil, home: home) == "/Users/me/.claude")
    }

    @Test func shortNames() {
        #expect(ClaudeConfigPath.shortName("/Users/me/.claude", home: home) == "default")
        #expect(ClaudeConfigPath.shortName("/Users/me/.claude-work", home: home) == "work")
        #expect(ClaudeConfigPath.shortName("/Volumes/x/profiles/acme", home: home) == "acme")
    }

    private func window(_ used: Double, _ resets: Double) -> StatuslinePayload.Window {
        .init(usedPercentage: used, resetsAt: resets)
    }

    @Test func staleLowerReadingDoesNotWin() {
        let current = ["five_hour": window(5, 1000)]
        #expect(LimitMerge.merge(current: current, fresh: ["five_hour": window(1, 1000)])["five_hour"]?.usedPercentage == 5)
        #expect(LimitMerge.merge(current: current, fresh: ["five_hour": window(7, 1030)])["five_hour"]?.usedPercentage == 7)
    }

    @Test func newWindowWinsOldWindowLoses() {
        let current = ["five_hour": window(80, 1000)]
        let reset = LimitMerge.merge(current: current, fresh: ["five_hour": window(2, 19000)])
        #expect(reset["five_hour"]?.usedPercentage == 2)
        let old = LimitMerge.merge(current: ["five_hour": window(2, 19000)], fresh: ["five_hour": window(80, 1000)])
        #expect(old["five_hour"]?.usedPercentage == 2)
    }

    @Test func windowsMissingFromAReadingAreKept() {
        let merged = LimitMerge.merge(current: ["seven_day": window(9, 5000)], fresh: ["five_hour": window(1, 1000)])
        #expect(Set(merged.keys) == ["seven_day", "five_hour"])
    }
}

@Suite struct UsageCommandTests {
    let minsk = TimeZone(identifier: "Europe/Minsk")!
    let sample = """
    You are currently using your subscription to power your Claude Code usage

    Current session: 7% used · resets Sep 30 at 7:49pm (Europe/Minsk)
    Current week (all models): 11% used · resets Oct 6 at 1:59pm (Europe/Minsk)
    Current week (Fable): 12% used · resets Oct 7 at 8am (Europe/Minsk)

    What's contributing to your limits usage?
      84% of your usage was at >150k context
    """

    private func date(_ text: String) -> Double {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text)!.timeIntervalSince1970
    }

    @Test func parsesEveryWindow() {
        let now = Date(timeIntervalSince1970: date("2026-09-30T14:10:00Z"))
        let windows = UsageCommand.parse(sample, now: now, timeZone: minsk)
        #expect(Set(windows.keys) == ["five_hour", "seven_day", "seven_day_fable"])
        #expect(windows["five_hour"]?.usedPercentage == 7)
        #expect(windows["five_hour"]?.resetsAt == date("2026-09-30T16:49:00Z"))
        #expect(windows["seven_day"]?.resetsAt == date("2026-10-06T10:59:00Z"))
        #expect(windows["seven_day_fable"]?.usedPercentage == 12)
        #expect(windows["seven_day_fable"]?.resetsAt == date("2026-10-07T05:00:00Z"))
        #expect(LimitKey.title("seven_day_fable") == "Weekly · Fable")
    }

    @Test func yearRollsOverAndTimeOnlyMeansToday() {
        let now = Date(timeIntervalSince1970: date("2026-12-30T12:00:00Z"))
        let windows = UsageCommand.parse("Current week (all models): 3% used · resets Jan 2 at 9am (UTC)\nCurrent session: 1% used · resets 3pm (UTC)", now: now, timeZone: minsk)
        #expect(windows["seven_day"]?.resetsAt == date("2027-01-02T09:00:00Z"))
        #expect(windows["five_hour"]?.resetsAt == date("2026-12-30T15:00:00Z"))
    }

    @Test func ignoresEverythingElse() {
        #expect(UsageCommand.parse("Error: not logged in\nUsage credits: $75 spent").isEmpty)
        #expect(UsageCommand.parse("Current session: soon").isEmpty)
    }
}
