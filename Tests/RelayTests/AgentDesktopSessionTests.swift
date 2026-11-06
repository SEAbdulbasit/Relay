import Foundation
import Testing
@testable import Relay

@MainActor
struct AgentDesktopSessionTests {
    private static func result(command: String, rendered: Bool = false) -> AgentDesktopEnvelope {
        AgentDesktopBridge.parseEnvelope(rawJSON: "{\"ok\":true,\"command\":\"\(command)\",\"data\":{\"rendered\":\(rendered)}}", defaultCommand: command)
    }

    private static var startup: AgentDesktopEnvelope {
        AgentDesktopBridge.parseEnvelope(rawJSON: #"{"ok":true,"command":"session","data":{"session_id":"relay-test-session"}}"#, defaultCommand: "session")
    }

    @Test func stopDuringSetupOrdersDisableAfterEnableAndPreventsStaleRenderedState() async {
        var calls: [[String]] = []
        var started = false
        var release: CheckedContinuation<Void, Never>?
        let session = AgentDesktopSession { args, id in
            if args.first == "session" { return Self.startup }
            #expect(id.hasPrefix("relay-"))
            calls.append(args)
            if args[1] == "enable" {
                started = true
                await withCheckedContinuation { release = $0 }
            }
            return Self.result(command: "cursor-overlay", rendered: args[1] == "enable")
        }
        let setup = Task { await session.show(label: "Type") }
        for _ in 0..<100 where !started { await Task.yield() }
        #expect(started)
        let stop = session.stop()
        release?.resume()
        #expect(await setup.value == false)
        #expect(await stop?.value == true)
        #expect(calls.map { $0[1] } == ["enable", "disable"])
        #expect(!session.isRendered)
        #expect(!calls.flatMap { $0 }.contains("--headed"))
    }

    @Test func newSetupWaitsForPriorStopAndKeepsItsOwnNamespace() async {
        var calls: [String] = []
        var scopes: [String] = []
        let session = AgentDesktopSession { args, id in
            if args.first == "session" { return Self.startup }
            calls.append(args[1]); scopes.append(id)
            return Self.result(command: "cursor-overlay", rendered: args[1] == "enable")
        }
        #expect(await session.show(label: "Click"))
        let stop = session.stop()
        #expect(await session.show(label: "Scroll"))
        #expect(await stop?.value == true)
        #expect(calls == ["enable", "disable", "enable"])
        #expect(Set(scopes) == [session.id])
        #expect(session.id != AgentDesktopSession().id)
        _ = await session.stop()?.value
    }

    @Test func savedSettingDoesNotClaimACursorWasDrawn() async {
        let session = AgentDesktopSession { args, _ in args.first == "session" ? Self.startup : Self.result(command: "cursor-overlay") }
        #expect(await session.show(label: "Type") == false)
        #expect(!session.isRendered)
        _ = await session.stop()?.value
    }

    @Test func staticPageTextWithoutActionableRefsIsRetained() {
        let raw = #"{"ok":true,"command":"snapshot","data":{"app":"Chrome","tree":{"role":"document","children":[{"role":"text","name":"No conversations found"},{"role":"securetextfield","value":"secret"},{"role":"button","name":"Search","ref_id":"@snapshot:e1"}]}}}"#
        let result = AgentDesktopBridge.parseEnvelope(rawJSON: raw, defaultCommand: "snapshot")
        #expect(result.formattedSummary.contains("No conversations found"))
        #expect(result.formattedSummary.contains("element_id=@snapshot:e1"))
        #expect(!result.formattedSummary.contains("secret"))
    }
}
