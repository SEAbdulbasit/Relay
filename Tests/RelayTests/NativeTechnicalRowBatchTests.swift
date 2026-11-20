import ApplicationServices
import Foundation
import Testing
@testable import Relay

@MainActor @Suite struct NativeTechnicalRowBatchTests {
    private typealias Batch = NativeTechnicalRowBatch
    private func error(_ status: AXError) throws -> AXValue {
        var value = status
        return try #require(AXValueCreate(.axError, &value))
    }
    private func rows() -> [AnyObject] {
        ["AXTextField" as NSString, "AXSecureTextField" as NSString, kCFBooleanTrue, kCFBooleanFalse, kCFBooleanFalse]
    }
    @Test func technicalWhitelistAndPositiveProtectionRemainExact() throws {
        #expect(Batch.attributeNames == [kAXRoleAttribute, kAXSubroleAttribute, "AXProtectedContent", "AXContainsProtectedContent", "AXHidden"])
        let result = try Batch.decode(status: .success, values: rows() as CFArray, names: Set(Batch.attributeNames))
        #expect(result.role == "AXTextField")
        #expect(result.subrole == "AXSecureTextField")
        #expect(result.protectionFlags == [.reported(true), .reported(false)])
        #expect(result.hidden == .reported(false))
    }
    @Test func unreportedIsOnlyUnadvertisedUnsupported() throws {
        let unsupported = try error(.attributeUnsupported)
        let result = try Batch.decode(status: .success,
            values: ["AXGroup" as NSString, unsupported, unsupported, unsupported, unsupported] as CFArray,
            names: [kAXRoleAttribute])
        #expect(result.subrole.isEmpty)
        #expect(result.protectionFlags == [.unreported, .unreported])
        #expect(result.hidden == .unreported)
        for index in 1..<5 {
            var input = rows(); input[index] = unsupported
            #expect(throws: NativeOrdinaryWindowPolicySource.Failure.incomplete) {
                _ = try Batch.decode(status: .success, values: input as CFArray, names: Set(Batch.attributeNames))
            }
        }
    }
    @Test func nullNoValueAndMalformedSlotsNeverBecomeSafeDefaults() throws {
        for index in 0..<5 {
            for invalid in [kCFNull as AnyObject, try error(.noValue), try error(.cannotComplete), NSNumber(value: 7)] {
                var input = rows(); input[index] = invalid
                #expect(throws: NativeOrdinaryWindowPolicySource.Failure.incomplete) {
                    _ = try Batch.decode(status: .success, values: input as CFArray, names: [])
                }
            }
        }
    }
    @Test func malformedBatchAndByteOverflowRefuse() throws {
        for input in [nil, "invalid" as CFString, [] as CFArray, Array(rows().dropLast()) as CFArray] as [CFTypeRef?] {
            #expect(throws: NativeOrdinaryWindowPolicySource.Failure.incomplete) {
                _ = try Batch.decode(status: .success, values: input, names: [])
            }
        }
        #expect(throws: NativeOrdinaryWindowPolicySource.Failure.incomplete) {
            _ = try Batch.decode(status: .cannotComplete, values: rows() as CFArray, names: [])
        }
        for index in 0..<2 {
            var input = rows(); input[index] = String(repeating: "é", count: 513) as NSString
            #expect(throws: NativeOrdinaryWindowPolicySource.Failure.incomplete) {
                _ = try Batch.decode(status: .success, values: input as CFArray, names: Set(Batch.attributeNames))
            }
        }
    }
}
