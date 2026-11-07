import AppKit
import CoreServices
import Foundation
import Testing
@testable import Relay

@MainActor
struct BrowserURLDispatchTests {
    private var target: BrowserURLDispatch.Target {
        .init(processID: 4242, launchedAt: Date(timeIntervalSince1970: 1), bundleID: "com.google.Chrome",
              bundleURL: URL(fileURLWithPath: "/Applications/Google Chrome.app", isDirectory: true))
    }

    @Test func exactProcessFixedEventAndURLDataAreTheOnlyDispatch() throws {
        let url = try #require(URL(string: "http://127.0.0.1:8765/fixture?q=tell%20application%20Mail"))
        let request = try BrowserURLDispatch.prepare(url, target: target)
        var identityChecks = 0
        var sends = 0
        try BrowserURLDispatch.perform(request, isCurrent: { current in
            identityChecks += 1
            #expect(current == target)
            return true
        }, preflight: { address, eventClass, eventID, askUser in
            #expect(address.data == NSAppleEventDescriptor(processIdentifier: target.processID).data)
            #expect(eventClass == 0x4755524C && eventID == 0x4755524C)
            #expect(!askUser)
            return noErr
        }, send: { event, options, timeout in
            sends += 1
            #expect(event.eventClass == 0x4755524C)
            #expect(event.eventID == 0x4755524C)
            #expect(event.attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr))?.data == NSAppleEventDescriptor(processIdentifier: target.processID).data)
            #expect(event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue == url.absoluteString)
            #expect(options.contains(.neverInteract) && options.contains(.dontRecord) && options.contains(.waitForReply))
            #expect(options.contains(.init(rawValue: UInt(kAEDoNotPromptForUserConsent))))
            #expect(timeout == 2)
            return .init(eventClass: 0, eventID: 0, targetDescriptor: nil, returnID: 0, transactionID: 0)
        })
        #expect(identityChecks == 2)
        #expect(sends == 1)
    }

    @Test func unsafeDestinationsAndUnqualifiedApplicationsCannotPrepare() throws {
        for raw in ["file:///tmp/fixture.txt", "javascript:alert(1)", "https://user:secret@example.invalid/", "https://example.invalid/%0Ainjected"] {
            let url = try #require(URL(string: raw))
            #expect(throws: BrowserURLDispatch.Failure.self) { try BrowserURLDispatch.prepare(url, target: target) }
        }
        let url = try #require(URL(string: "https://example.invalid/"))
        let wrong = BrowserURLDispatch.Target(processID: target.processID, launchedAt: target.launchedAt,
                                              bundleID: "com.apple.Terminal", bundleURL: target.bundleURL)
        #expect(throws: BrowserURLDispatch.Failure.self) { try BrowserURLDispatch.prepare(url, target: wrong) }
    }

    @Test func deniedOrMissingPermissionDoesNotDispatchOrRetry() throws {
        let request = try BrowserURLDispatch.prepare(#require(URL(string: "https://example.invalid/")), target: target)
        for permission in [OSStatus(errAEEventWouldRequireUserConsent), OSStatus(errAEEventNotPermitted), OSStatus(procNotFound)] {
            var sends = 0
            #expect(throws: BrowserURLDispatch.Failure.self) {
                try BrowserURLDispatch.perform(request, isCurrent: { _ in true }, preflight: { _, _, _, _ in permission }, send: { _, _, _ in
                    sends += 1
                    return .null()
                })
            }
            #expect(sends == 0)
        }
    }

    @Test func changedIdentityBeforeOrAfterPermissionPreflightCannotDispatch() throws {
        let request = try BrowserURLDispatch.prepare(#require(URL(string: "https://example.invalid/")), target: target)
        for failsAt in [1, 2] {
            var checks = 0
            var sends = 0
            #expect(throws: BrowserURLDispatch.Failure.self) {
                try BrowserURLDispatch.perform(request, isCurrent: { _ in checks += 1; return checks != failsAt },
                    preflight: { _, _, _, _ in noErr }, send: { _, _, _ in sends += 1; return .null() })
            }
            #expect(sends == 0)
        }
    }

    @Test func timeoutAfterOneDispatchNeverRetries() throws {
        let request = try BrowserURLDispatch.prepare(#require(URL(string: "https://example.invalid/")), target: target)
        var sends = 0
        #expect(throws: BrowserURLDispatch.Failure.self) {
            try BrowserURLDispatch.perform(request, isCurrent: { _ in true }, preflight: { _, _, _, _ in noErr }, send: { _, _, _ in
                sends += 1
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(errAETimeout))
            })
        }
        #expect(sends == 1)
    }

    @Test func errorReplyAfterOneDispatchNeverRetries() throws {
        let request = try BrowserURLDispatch.prepare(#require(URL(string: "https://example.invalid/")), target: target)
        var sends = 0
        #expect(throws: BrowserURLDispatch.Failure.self) {
            try BrowserURLDispatch.perform(request, isCurrent: { _ in true }, preflight: { _, _, _, _ in noErr }, send: { _, _, _ in
                sends += 1
                let reply = NSAppleEventDescriptor(eventClass: 0, eventID: 0, targetDescriptor: nil, returnID: 0, transactionID: 0)
                reply.setParam(.init(int32: Int32(errAEEventNotHandled)), forKeyword: AEKeyword(keyErrorNumber))
                return reply
            })
        }
        #expect(sends == 1)
    }

    @Test func cancellationDuringPreflightCannotDispatch() async throws {
        let request = try BrowserURLDispatch.prepare(#require(URL(string: "https://example.invalid/")), target: target)
        var sends = 0
        let operation = Task { @MainActor in
            try BrowserURLDispatch.perform(request, isCurrent: { _ in true }, preflight: { _, _, _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return noErr
            }, send: { _, _, _ in sends += 1; return .null() })
        }
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(sends == 0)
    }

    @Test func expiryDuringPermissionPreflightCannotDispatch() throws {
        let prepared = Date(timeIntervalSince1970: 1000)
        var now = prepared
        let request = try BrowserURLDispatch.prepare(#require(URL(string: "https://example.invalid/")), target: target,
                                                     deadline: prepared.addingTimeInterval(30), now: prepared)
        var sends = 0
        #expect(throws: BrowserURLDispatch.Failure.self) {
            try BrowserURLDispatch.perform(request, now: { now }, isCurrent: { _ in true }, preflight: { _, _, _, _ in
                now = prepared.addingTimeInterval(31)
                return noErr
            }, send: { _, _, _ in sends += 1; return .null() })
        }
        #expect(sends == 0)
    }

    @Test func rollbackAndUnboundedDeadlinesRefuseBeforePermissionPreflight() throws {
        let prepared = Date(timeIntervalSince1970: 1000)
        let url = try #require(URL(string: "https://example.invalid/"))
        for deadline in [prepared, prepared.addingTimeInterval(-1), prepared.addingTimeInterval(31), Date(timeIntervalSince1970: .infinity)] {
            #expect(throws: BrowserURLDispatch.Failure.self) { try BrowserURLDispatch.prepare(url, target: target, deadline: deadline, now: prepared) }
        }
        let request = try BrowserURLDispatch.prepare(url, target: target, deadline: prepared.addingTimeInterval(30), now: prepared)
        var preflights = 0
        var sends = 0
        #expect(throws: BrowserURLDispatch.Failure.self) {
            try BrowserURLDispatch.perform(request, now: { prepared.addingTimeInterval(-1) }, isCurrent: { _ in true },
                preflight: { _, _, _, _ in preflights += 1; return noErr }, send: { _, _, _ in sends += 1; return .null() })
        }
        #expect(preflights == 0 && sends == 0)
    }

    @Test func replyTimeoutCannotOutlastTheRemainingNavigationLease() throws {
        let prepared = Date(timeIntervalSince1970: 1000)
        let request = try BrowserURLDispatch.prepare(#require(URL(string: "https://example.invalid/")), target: target,
                                                     deadline: prepared.addingTimeInterval(1), now: prepared)
        try BrowserURLDispatch.perform(request, now: { prepared }, isCurrent: { _ in true }, preflight: { _, _, _, _ in noErr },
            send: { _, _, timeout in
                #expect(timeout == 1)
                return .init(eventClass: 0, eventID: 0, targetDescriptor: nil, returnID: 0, transactionID: 0)
            })
    }
}
