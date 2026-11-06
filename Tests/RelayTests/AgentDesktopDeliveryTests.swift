import Foundation
import Testing
@testable import Relay

@Suite("Agent desktop value delivery evidence")
struct AgentDesktopDeliveryTests {
    private func result(ok: Bool = true, delivery: String?, value: String?, command: String = "set-value") throws -> AgentDesktopEnvelope {
        var payload: [String: Any] = [:]
        if let delivery { payload["disposition"] = ["delivery": delivery, "retry": "unsafe"] }
        if let value { payload["post_state"] = ["value": value] }
        let data = try JSONSerialization.data(withJSONObject: ["ok": ok, "command": command, "data": payload])
        return AgentDesktopBridge.parseEnvelope(rawJSON: String(decoding: data, as: UTF8.self), defaultCommand: command)
    }

    @Test(arguments: ["delivered_unverified", "not_delivered", "unknown"])
    func dispatchWithoutVerifiedDeliveryCannotProveValue(delivery: String) throws {
        #expect(try !result(delivery: delivery, value: "done").verifiesTextValue("done"))
    }

    @Test func requiresMatchingReadbackAndSuccess() throws {
        #expect(try !result(delivery: "delivered_verified", value: "different").verifiesTextValue("done"))
        #expect(try !result(delivery: "delivered_verified", value: nil).verifiesTextValue("done"))
        #expect(try !result(delivery: nil, value: "done").verifiesTextValue("done"))
        #expect(try !result(ok: false, delivery: "delivered_verified", value: "done").verifiesTextValue("done"))
        #expect(try !result(delivery: "delivered_verified", value: "done", command: "type").verifiesTextValue("done"))
    }

    @Test(arguments: ["", "Relay café مرحبا 👋"])
    func acceptsExactEmptyAndUnicodeValues(value: String) throws {
        #expect(try result(delivery: "delivered_verified", value: value).verifiesTextValue(value))
    }
}
