import Darwin
import Foundation
import Testing
@testable import Relay

@Suite(.serialized)
@MainActor struct NativeControlTransportTests {
    @Test func finiteCommandsEmitOnlyQualifiedPrimitiveArguments() throws {
        let app = "/Applications/Owned Fixture.app"
        #expect(try OwnedNativeComputerUseClient.Command.click(.init(x: 12, y: 24)).arguments(app: app) == [
            "app": .string(app), "x": .number(12), "y": .number(24), "click_count": .number(1), "mouse_button": .string("left")])
        #expect(try OwnedNativeComputerUseClient.Command.key(.left).arguments(app: app)["key"] == .string("Left"))
        #expect(try OwnedNativeComputerUseClient.Command.typeUnsentText("ASCII draft").arguments(app: app)["text"] == .string("ASCII draft"))
        #expect(throws: OwnedNativeComputerUseClient.Failure.malformedResponse) {
            try OwnedNativeComputerUseClient.Command.typeUnsentText("send\n").arguments(app: app)
        }
        #expect(throws: OwnedNativeComputerUseClient.Failure.malformedResponse) {
            try OwnedNativeComputerUseClient.Command.click(.init(x: .nan, y: 0)).arguments(app: app)
        }
    }

    @Test func duplicateMutationIDCannotReplayOrChangeAnyArgumentOrTool() async throws {
        let inputGate = NativeInputRevocation()
        let transport = NativeControlTransport(), client = try await ready(transport)
        let first = try await client.mutate(requestID: "input", app: app, command: .click(.init(x: 2, y: 3)), revocation: inputGate, preflight: { _ in .init(notAfter: .now.advanced(by: .seconds(30)), revocation: inputGate) })
        #expect(try await client.mutate(requestID: "input", app: app, command: .click(.init(x: 2, y: 3)), revocation: inputGate, preflight: { _ in .init(notAfter: .now.advanced(by: .seconds(30)), revocation: inputGate) }) == first)
        try await expectNotDispatched(OwnedNativeComputerUseClient.Failure.duplicateRequest) {
            try await client.mutate(requestID: "input", app: app, command: .click(.init(x: 2, y: 4)), revocation: inputGate, preflight: { _ in .init(notAfter: .now.advanced(by: .seconds(30)), revocation: inputGate) })
        }
        try await expectNotDispatched(OwnedNativeComputerUseClient.Failure.duplicateRequest) {
            try await client.mutate(requestID: "input", app: app, command: .key(.left), revocation: inputGate, preflight: { _ in .init(notAfter: .now.advanced(by: .seconds(30)), revocation: inputGate) })
        }
        await #expect(throws: OwnedNativeComputerUseClient.Failure.duplicateRequest) {
            try await client.state(requestID: "input", app: app)
        }
        #expect(await transport.calls.count == 1)
        await client.close()
    }

    @Test func evictedMutationReceiptNeverMakesItsRequestIDReusable() async throws {
        let inputGate = NativeInputRevocation()
        let transport = NativeControlTransport(), client = try await ready(transport)
        for i in 0..<9 { _ = try await client.mutate(requestID: "key-\(i)", app: app, command: .key(.right), revocation: inputGate, preflight: { _ in .init(notAfter: .now.advanced(by: .seconds(30)), revocation: inputGate) }) }
        try await expectNotDispatched(OwnedNativeComputerUseClient.Failure.duplicateRequest) {
            try await client.mutate(requestID: "key-0", app: app, command: .key(.right), revocation: inputGate, preflight: { _ in .init(notAfter: .now.advanced(by: .seconds(30)), revocation: inputGate) })
        }
        #expect(await transport.calls.count == 9)
        await client.close()
    }

    @Test func finalGateRunsAfterFIFOAdmissionAndRevocationSendsNoMutation() async throws {
        let inputGate = NativeInputRevocation()
        let transport = NativeControlTransport(), client = try await ready(transport)
        await transport.pause()
        let first = Task { try await client.state(requestID: "read", app: app) }
        try await wait { await transport.calls.count == 1 }
        var admitted = true, gateCount = 0
        let queued = Task { try await client.mutate(requestID: "input", app: app, command: .key(.right), revocation: inputGate, preflight: { _ in
            gateCount += 1; if !admitted { throw NativeControlSession.Failure.unqualifiedEffect }
            return .init(notAfter: .now.advanced(by: .seconds(30)), revocation: inputGate)
        }) }
        for _ in 0..<20 { await Task.yield() }
        #expect(gateCount == 0)
        admitted = false
        await transport.releaseOne(); _ = try await first.value
        try await expectNotDispatched(NativeControlSession.Failure.unqualifiedEffect) { try await queued.value }
        let callCount = await transport.calls.count
        #expect(gateCount == 1 && callCount == 1)
        await transport.unpause()
        _ = try await client.state(requestID: "next-read", app: app)
        #expect(await transport.closeCount == 0)
        await client.close()
    }

    @Test func cachedReceiptStillRequiresCurrentTrustedGateWithoutReplaying() async throws {
        let inputGate = NativeInputRevocation()
        let transport = NativeControlTransport(), client = try await ready(transport)
        _ = try await client.mutate(requestID: "input", app: app, command: .key(.right), revocation: inputGate, preflight: { _ in .init(notAfter: .now.advanced(by: .seconds(30)), revocation: inputGate) })
        try await expectNotDispatched(NativeControlSession.Failure.unqualifiedEffect) {
            try await client.mutate(requestID: "input", app: app, command: .key(.right), revocation: inputGate, preflight: { _ in
                throw NativeControlSession.Failure.unqualifiedEffect
            })
        }
        #expect(await transport.calls.count == 1)
        await client.close()
    }

    @Test func reservedStateAndMutationAreContiguousDespiteAnotherQueuedNativeRead() async throws {
        let inputGate = NativeInputRevocation()
        let transport = NativeControlTransport(), client = try await ready(transport)
        await transport.pause()
        let owner = Task { try await client.mutate(requestID: "input", app: app, command: .key(.right), revocation: inputGate, preflight: { reservation in
            _ = try await reservation.state(requestID: "fresh-inside-reservation", app: self.app)
            return .init(notAfter: .now.advanced(by: .seconds(2)), revocation: inputGate)
        }) }
        try await wait { await transport.calls.count == 1 }
        let queued = Task { try await client.state(requestID: "foreign-queued-read", app: app) }
        for _ in 0..<20 { await Task.yield() }
        await transport.unpause(); await transport.releaseOne()
        _ = try await owner.value; _ = try await queued.value
        let calls = await transport.calls
        #expect(calls.map { $0["tool"]?.string } == ["get_app_state", "press_key", "get_app_state"])
        await client.close()
    }

    @Test func reservationCannotReadAnotherAppAndExpiresBeforeQueueRelease() async throws {
        let inputGate = NativeInputRevocation()
        let transport = NativeControlTransport(), client = try await ready(transport)
        var retained: OwnedNativeComputerUseClient.ReservedState?
        _ = try await client.mutate(requestID: "input", app: app, command: .key(.right), revocation: inputGate, preflight: { reservation in retained = reservation; return .init(notAfter: .now.advanced(by: .seconds(30)), revocation: inputGate) })
        let expired = try #require(retained)
        await #expect(throws: OwnedNativeComputerUseClient.Failure.closed) {
            try await expired.state(requestID: "expired", app: app)
        }
        try await expectNotDispatched(OwnedNativeComputerUseClient.Failure.closed) {
            try await client.mutate(requestID: "next-input", app: app, command: .key(.right), revocation: inputGate, preflight: { reservation in
                _ = try await reservation.state(requestID: "wrong-app", app: "/Applications/Another Fixture.app")
                return .init(notAfter: .now.advanced(by: .seconds(30)), revocation: inputGate)
            })
        }
        #expect(await transport.calls.count == 1)
        await client.close()
    }

    @Test func expiryAfterActorHopIsStillDefinitivelyNotDispatched() async throws {
        let inputGate = NativeInputRevocation()
        let transport = NativeControlTransport(), client = try await ready(transport)
        await transport.delayInputBoundary(.seconds(3))
        try await expectNotDispatched(OwnedNativeComputerUseClient.Failure.timeout) {
            try await client.mutate(requestID: "expired-input", app: app, command: .click(.init(x: 2, y: 3)), revocation: inputGate, preflight: { _ in
                .init(notAfter: .now.advanced(by: .seconds(2)), revocation: inputGate)
            })
        }
        #expect(await transport.calls.isEmpty)
        await client.close()
    }

    @Test func schemaDriftRefusesBeforeTrustedGateOrNativeDispatch() async throws {
        let inputGate = NativeInputRevocation()
        let transport = NativeControlTransport()
        await transport.corruptClickSchema()
        let client = try await ready(transport)
        var gateCount = 0
        try await expectNotDispatched(OwnedNativeComputerUseClient.Failure.unsupportedCatalog) {
            try await client.mutate(requestID: "input", app: app, command: .click(.init(x: 2, y: 3)), revocation: inputGate, preflight: { _ in gateCount += 1; return .init(notAfter: .now.advanced(by: .seconds(30)), revocation: inputGate) })
        }
        let noCalls = await transport.calls.isEmpty
        #expect(gateCount == 0 && noCalls)
        await client.close()
    }

    @Test func lostMutationResponseClosesOwnerAndCannotAutomaticallyReplay() async throws {
        let inputGate = NativeInputRevocation()
        let transport = NativeControlTransport(), client = try await ready(transport)
        await transport.failNext()
        do {
            _ = try await client.mutate(requestID: "input", app: app, command: .key(.right), revocation: inputGate, preflight: { _ in .init(notAfter: .now.advanced(by: .seconds(30)), revocation: inputGate) })
            Issue.record("Lost response must be uncertain.")
        } catch OwnedNativeComputerUseClient.MutationFailure.uncertain(let error) {
            #expect(error as? OwnedNativeComputerUseClient.Failure == .timeout)
        }
        try await expectNotDispatched(OwnedNativeComputerUseClient.Failure.closed) {
            try await client.mutate(requestID: "input", app: app, command: .key(.right), revocation: inputGate, preflight: { _ in .init(notAfter: .now.advanced(by: .seconds(30)), revocation: inputGate) })
        }
        let calls = await transport.calls.count, closes = await transport.closeCount
        #expect(calls == 1 && closes == 1)
    }

    @Test func partialOwnedStreamIsPoisonedClosedAndCannotReceiveAnotherRequest() async throws {
        let inputGate = NativeInputRevocation()
        let transport = NativeControlTransport(), client = try await ready(transport)
        await transport.partialNextInput()
        do {
            _ = try await client.mutate(requestID: "partial-input", app: app, command: .key(.right), revocation: inputGate, preflight: { _ in
                .init(notAfter: .now.advanced(by: .seconds(2)), revocation: inputGate)
            })
            Issue.record("A partial native frame must be uncertain.")
        } catch OwnedNativeComputerUseClient.MutationFailure.uncertain(let error) {
            #expect(error as? OwnedNativeComputerUseClient.Failure == .transportWrite)
        }
        let prefix = await transport.partialBytes, closes = await transport.closeCount
        #expect(prefix == Data("{\"synth".utf8) && closes == 1)
        await #expect(throws: OwnedNativeComputerUseClient.Failure.closed) { try await client.state(requestID: "must-not-append", app: app) }
        try await expectNotDispatched(OwnedNativeComputerUseClient.Failure.closed) {
            try await client.mutate(requestID: "partial-input", app: app, command: .key(.right), revocation: inputGate, preflight: { _ in
                .init(notAfter: .now.advanced(by: .seconds(2)), revocation: inputGate)
            })
        }
        #expect(await transport.partialBytes == prefix)
        #expect(await transport.calls.isEmpty)
    }

    @Test func unsupportedProviderUnicodeMakesZeroNativeToolCallsAndNoFallback() async throws {
        let inputGate = NativeInputRevocation()
        let transport = NativeControlTransport(), client = try await ready(transport)
        for text in ["café", "🌍", "你好", "cafe\u{301}", "—"] {
            try await expectNotDispatched(OwnedNativeComputerUseClient.Failure.unsupportedKeyboardText) {
                try await client.mutate(requestID: UUID().uuidString, app: app, command: .typeUnsentText(text), revocation: inputGate, preflight: { _ in
                    Issue.record("Unsupported provider text must be refused before its final gate.")
                    return .init(notAfter: .now.advanced(by: .seconds(2)), revocation: inputGate)
                })
            }
        }
        #expect(await transport.calls.isEmpty)
        #expect(await transport.closeCount == 0)
        _ = try await client.state(requestID: "still-ready", app: app)
        #expect(await transport.calls.count == 1)
        await client.close()
    }

    @Test func AXReservationKeepsFreshReadLocalWriteAndReadbackAheadOfQueuedNativeInput() async throws {
        let inputGate = NativeInputRevocation()
        let transport = NativeControlTransport(), client = try await ready(transport), gate = NativeInputRevocation(), probe = AXReservationProbe()
        let bound = try probe.bind(gate)
        await transport.pause()
        let owner = Task { try await client.reserveAXInsertion(requestID: "original-AX-call", app: app, fingerprint: Data(repeating: 1, count: 32), revocation: gate, prepare: { read in
            _ = try await read.state(requestID: "fresh-before-AX", app: self.app)
            return .init(execute: { probe.executions += 1; return bound.binding.execute(bound.prepared, authorization: probe.authorization) }, readback: { read, _ in
                do { _ = try await read.state(requestID: "readback-after-AX", app: self.app) }
                catch { Issue.record("The original-target readback unexpectedly failed: \(error).") }
            })
        }) }
        try await wait { await transport.calls.count == 1 }
        let queued = Task { try await client.mutate(requestID: "queued-key", app: app, command: .key(.left), revocation: inputGate, preflight: { _ in
            .init(notAfter: .now.advanced(by: .seconds(2)), revocation: inputGate)
        }) }
        for _ in 0..<20 { await Task.yield() }
        let pausedCalls = await transport.calls.count
        #expect(probe.writes == 0 && pausedCalls == 1)
        await transport.unpause(); await transport.releaseOne()
        #expect(try await owner.value == .inserted)
        _ = try await queued.value
        let calls = await transport.calls
        #expect(calls.map { $0["tool"]?.string } == ["get_app_state", "get_app_state", "press_key"])
        #expect(probe.writes == 1 && probe.consumes == 1 && probe.value.utf16.elementsEqual(probe.literal.utf16))
        bound.binding.stop(); await client.close()
    }

    @Test func AXReservationIDsCannotReplayOrChangeEffectAndNoProviderReceiptIsInvented() async throws {
        let inputGate = NativeInputRevocation()
        let transport = NativeControlTransport(), client = try await ready(transport), gate = NativeInputRevocation(), probe = AXReservationProbe()
        let bound = try probe.bind(gate)
        let preparation: @MainActor @Sendable (OwnedNativeComputerUseClient.ReservedState) async throws -> OwnedNativeComputerUseClient.AXInsertionOperation = { read in
            _ = try await read.state(requestID: "one-before", app: self.app)
            return .init(execute: { probe.executions += 1; return bound.binding.execute(bound.prepared, authorization: probe.authorization) }, readback: { read, _ in
                _ = try? await read.state(requestID: "one-after", app: self.app)
            })
        }
        #expect(try await client.reserveAXInsertion(requestID: "one-AX", app: app, fingerprint: Data(repeating: 1, count: 32), revocation: gate, prepare: preparation) == .inserted)
        for fingerprint in [Data(repeating: 1, count: 32), Data(repeating: 2, count: 32)] {
            try await expectAXNotDispatched(OwnedNativeComputerUseClient.Failure.duplicateRequest) {
                try await client.reserveAXInsertion(requestID: "one-AX", app: app, fingerprint: fingerprint, revocation: gate, prepare: preparation)
            }
        }
        try await expectNotDispatched(OwnedNativeComputerUseClient.Failure.duplicateRequest) {
            try await client.mutate(requestID: "one-AX", app: app, command: .key(.left), revocation: inputGate, preflight: { _ in .init(notAfter: .now.advanced(by: .seconds(2)), revocation: inputGate) })
        }
        let callCount = await transport.calls.count
        #expect(probe.writes == 1 && probe.executions == 1 && callCount == 2)
        bound.binding.stop(); await client.close()
    }

    @Test func AXFinalAdmissionHonorsARevocationDeliveredAtTheActorHop() async throws {
        let inputGate = NativeInputRevocation()
        let transport = NativeControlTransport(), client = try await ready(transport), gate = NativeInputRevocation(), probe = AXReservationProbe()
        let bound = try probe.bind(gate), readsBefore = probe.reads
        let outcome = try await client.reserveAXInsertion(requestID: "AX-stop-hop", app: app, fingerprint: Data(repeating: 1, count: 32), revocation: gate, prepare: { read in
            _ = try await read.state(requestID: "before-stop-hop", app: self.app)
            return .init(execute: {
                gate.revoke() // Delivered after FIFO admission, at entry to the MainActor.
                probe.executions += 1
                return bound.binding.execute(bound.prepared, authorization: probe.authorization)
            }, readback: { _, _ in })
        })
        #expect(outcome == .notDispatched(.stopped))
        #expect(probe.writes == 0 && probe.consumes == 0 && probe.reads == readsBefore)
        #expect(await transport.calls.count == 1)
        bound.binding.stop(); await client.close()
    }

    @Test func actualClientCloseRevokesTheSameAXGateWhilePreparationWaits() async throws {
        let inputGate = NativeInputRevocation()
        let transport = NativeControlTransport(), client = try await ready(transport), gate = NativeInputRevocation(), probe = AXReservationProbe()
        let bound = try probe.bind(gate), latch = AXReservationLatch()
        let owner = Task { try await client.reserveAXInsertion(requestID: "AX-close", app: app, fingerprint: Data(repeating: 1, count: 32), revocation: gate, prepare: { read in
            _ = try await read.state(requestID: "before-AX-close", app: self.app)
            probe.waiting = true; await latch.wait()
            return .init(execute: { probe.executions += 1; return bound.binding.execute(bound.prepared, authorization: probe.authorization) }, readback: { _, _ in })
        }) }
        try await wait { probe.waiting }
        await client.close()
        #expect(!gate.isActive)
        latch.release()
        try await expectAXNotDispatched(OwnedNativeComputerUseClient.Failure.closed) { try await owner.value }
        #expect(probe.writes == 0 && probe.executions == 0 && probe.consumes == 0)
        bound.binding.stop()
    }

    @Test func AXClientCloseAfterTheWriteStaysAttemptedUncertainAndNeverThrowsNoEffect() async throws {
        let inputGate = NativeInputRevocation()
        let transport = NativeControlTransport(), client = try await ready(transport), gate = NativeInputRevocation(), probe = AXReservationProbe()
        let bound = try probe.bind(gate)
        let outcome = try await client.reserveAXInsertion(requestID: "AX-close-after-write", app: app, fingerprint: Data(repeating: 1, count: 32), revocation: gate, prepare: { read in
            _ = try await read.state(requestID: "before-close-after-write", app: self.app)
            return .init(execute: { probe.executions += 1; return bound.binding.execute(bound.prepared, authorization: probe.authorization) }, readback: { _, _ in
                await client.close()
            })
        })
        #expect(outcome == .uncertain(.stoppedAfterDispatch) && !gate.isActive)
        let callCount = await transport.calls.count
        #expect(probe.writes == 1 && probe.consumes == 1 && callCount == 1)
        bound.binding.stop()
    }

    @Test func AXCaptureErrorsAreNotDispatchedAndCannotFallThroughToAnInput() async throws {
        let inputGate = NativeInputRevocation()
        let transport = NativeControlTransport(), client = try await ready(transport), gate = NativeInputRevocation(), probe = AXReservationProbe()
        let bound = try probe.bind(gate)
        await transport.failNext()
        try await expectAXNotDispatched(OwnedNativeComputerUseClient.Failure.timeout) {
            try await client.reserveAXInsertion(requestID: "AX-capture-fail", app: app, fingerprint: Data(repeating: 1, count: 32), revocation: gate, prepare: { read in
                _ = try await read.state(requestID: "failed-AX-capture", app: self.app)
                return .init(execute: { probe.executions += 1; return bound.binding.execute(bound.prepared, authorization: probe.authorization) }, readback: { _, _ in })
            })
        }
        #expect(probe.writes == 0 && probe.executions == 0 && probe.consumes == 0)
        let callCount = await transport.calls.count, closeCount = await transport.closeCount
        #expect(callCount == 1 && closeCount == 1)
        bound.binding.stop()
    }

    @Test func AXReservationAllowsOnlyTwoSequentialOriginalAppReadsAndThenExpires() async throws {
        let inputGate = NativeInputRevocation()
        let transport = NativeControlTransport(), client = try await ready(transport), gate = NativeInputRevocation(), probe = AXReservationProbe()
        let bound = try probe.bind(gate)
        var saved: OwnedNativeComputerUseClient.ReservedState?
        let outcome = try await client.reserveAXInsertion(requestID: "AX-bounded-read", app: app, fingerprint: Data(repeating: 1, count: 32), revocation: gate, prepare: { read in
            saved = read
            _ = try await read.state(requestID: "AX-first-read", app: self.app)
            return .init(execute: { bound.binding.execute(bound.prepared, authorization: probe.authorization) }, readback: { read, _ in
                _ = try? await read.state(requestID: "AX-second-read", app: self.app)
                await #expect(throws: OwnedNativeComputerUseClient.Failure.closed) { try await read.state(requestID: "AX-third-read", app: self.app) }
            })
        })
        #expect(outcome == .inserted && probe.writes == 1)
        let expired = try #require(saved)
        await #expect(throws: OwnedNativeComputerUseClient.Failure.closed) { try await expired.state(requestID: "AX-after-reservation", app: app) }
        #expect(await transport.calls.count == 2)
        bound.binding.stop(); await client.close()
    }

    @Test func AXReservationRequiresAFreshReadBeforeExecutionAndRefusesOtherApps() async throws {
        let inputGate = NativeInputRevocation()
        for skipsRead in [false, true] {
            let transport = NativeControlTransport(), client = try await ready(transport), gate = NativeInputRevocation(), probe = AXReservationProbe()
            let bound = try probe.bind(gate)
            try await expectAXNotDispatched(OwnedNativeComputerUseClient.Failure.closed) {
                try await client.reserveAXInsertion(requestID: "AX-unqualified-read", app: app, fingerprint: Data(repeating: 1, count: 32), revocation: gate, prepare: { read in
                    if !skipsRead { _ = try await read.state(requestID: "AX-other-app", app: "/Applications/Other Synthetic.app") }
                    return .init(execute: { probe.executions += 1; return bound.binding.execute(bound.prepared, authorization: probe.authorization) }, readback: { _, _ in })
                })
            }
            let noCalls = await transport.calls.isEmpty
            #expect(probe.writes == 0 && probe.executions == 0 && noCalls)
            bound.binding.stop(); await client.close()
        }
    }

    private func expectAXNotDispatched<E: Error & Equatable>(_ expected: E,
        body: () async throws -> NativeFocusedAXInsertion.Outcome) async throws {
        do { _ = try await body(); Issue.record("Expected a definitive AX not-dispatched rejection.") }
        catch OwnedNativeComputerUseClient.MutationFailure.notDispatched(let error) { #expect(error as? E == expected) }
    }

    private func expectNotDispatched<E: Error & Equatable>(_ expected: E,
        body: () async throws -> OwnedNativeComputerUseClient.NativeResult) async throws {
        do { _ = try await body(); Issue.record("Expected a definitive not-dispatched rejection.") }
        catch OwnedNativeComputerUseClient.MutationFailure.notDispatched(let error) { #expect(error as? E == expected) }
    }

    @Test func mismatchedFinalAdmissionGateRefusesBeforeAnyNativeInput() async throws {
        let transport = NativeControlTransport(), client = try await ready(transport)
        let ownedGate = NativeInputRevocation(), unrelatedGate = NativeInputRevocation()
        try await expectNotDispatched(OwnedNativeComputerUseClient.Failure.closed) {
            try await client.mutate(requestID: "wrong-admission-gate", app: app, command: .key(.left),
                revocation: ownedGate, preflight: { _ in
                    .init(notAfter: .now.advanced(by: .seconds(30)), revocation: unrelatedGate)
                })
        }
        #expect(await transport.calls.isEmpty)
        await client.close()
    }

    @Test func finalAdmissionCannotExtendTheActualOwnedReservationDeadline() async throws {
        let transport = NativeControlTransport(), client = try await ready(transport), gate = NativeInputRevocation()
        await transport.delayInputBoundary(.seconds(3))
        try await expectNotDispatched(OwnedNativeComputerUseClient.Failure.timeout) {
            try await client.mutate(requestID: "overlong-final-admission", app: app, command: .key(.left),
                revocation: gate, timeout: .seconds(1), preflight: { _ in
                    .init(notAfter: .now.advanced(by: .seconds(30)), revocation: gate)
                })
        }
        #expect(await transport.calls.isEmpty)
        await client.close()
    }

    @Test func clientCloseWhileNativePreflightWaitsRevokesItsActualFinalAdmissionGate() async throws {
        let transport = NativeControlTransport(), client = try await ready(transport), gate = NativeInputRevocation()
        let latch = AXReservationLatch()
        var entered = false
        let owner = Task { try await client.mutate(requestID: "close-during-native-preflight", app: app, command: .key(.left),
            revocation: gate, preflight: { read in
                entered = true; await latch.wait()
                return .init(notAfter: read.notAfter, revocation: gate)
            }) }
        try await wait { entered }
        await client.close()
        #expect(!gate.isActive)
        latch.release()
        try await expectNotDispatched(OwnedNativeComputerUseClient.Failure.closed) { try await owner.value }
        #expect(await transport.calls.isEmpty)
    }

    private var app: String { "/Applications/Owned Fixture.app" }
    private func ready(_ transport: NativeControlTransport) async throws -> OwnedNativeComputerUseClient {
        let client = OwnedNativeComputerUseClient(transport: transport.transport)
        try await client.start(workspace: URL(fileURLWithPath: "/private/tmp/OwnedNativeSynthetic", isDirectory: true))
        return client
    }
    private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 { if await condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
        throw NativeControlSession.Failure.busy
    }
}

@MainActor private final class AXReservationProbe {
    let literal = "cafe\u{301} 🌍"
    var value = "", selection = NSRange(location: 0, length: 0)
    var writes = 0, reads = 0, consumes = 0, executions = 0
    var waiting = false, reviewed = false
    func bind(_ gate: NativeInputRevocation) throws -> (binding: NativeFocusedAXInsertion, prepared: NativeFocusedAXInsertion.PreparedInsertion) {
        let binding = try NativeFocusedAXInsertion(access: .init(validateOriginalTarget: {}, metadata: {
            .init(role: "AXTextArea", subrole: "", protected: false, hidden: false, enabled: true, selectionWritable: true)
        }, contents: { [self] in
            reads += 1
            return .init(value: value, selection: selection, selectedText: "", attributedValue: NSAttributedString(string: value))
        }, writeSelectedText: { [self] literal in
            writes += 1; value = literal; selection = .init(location: literal.utf16.count, length: 0)
        }), sessionIsActive: { true }, admissionGate: gate)
        return (binding, try binding.prepare(literal))
    }
    var authorization: NativeFocusedAXInsertion.Authorization {
        .init(validateTaskSource: {}, revalidate: { [self] in
            guard !reviewed else { throw NativeFocusedAXInsertion.Failure.authorizationChanged }
        }, consume: { [self] in
            guard !reviewed else { throw NativeFocusedAXInsertion.Failure.authorizationChanged }
            reviewed = true; consumes += 1
        })
    }
}

@MainActor private final class AXReservationLatch {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { if !released { await withCheckedContinuation { continuation = $0 } } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private actor NativeControlTransport {
    private(set) var calls: [[String: JSONValue]] = []
    private(set) var closeCount = 0
    private var paused = false, fail = false, badClick = false
    private var inputDelay = Duration.zero
    private var partial = false
    private(set) var partialBytes = Data()
    private var gates: [CheckedContinuation<Void, Error>] = []
    nonisolated var transport: OwnedNativeComputerUseClient.Transport {
        .init(request: { [self] method, params, _ in try await request(method, params) }, initialized: {}, close: { [self] in await close() },
            input: { [self] method, params, _, admission in try await inputRequest(method, params, admission) })
    }
    func pause() { paused = true }
    func delayInputBoundary(_ duration: Duration) { inputDelay = duration }
    func partialNextInput() { partial = true }
    private func inputRequest(_ method: OwnedNativeComputerUseClient.Method, _ params: [String: JSONValue],
                              _ admission: OwnedNativeComputerUseClient.InputAdmission) async throws -> JSONValue {
        if partial {
            partial = false
            let pipe = Pipe(), bytes = Data("{\"synthetic\":\"partial native frame\"}\n".utf8)
            defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
            do {
                try NativeInputWriter.write(bytes, to: pipe.fileHandleForWriting.fileDescriptor, admission: admission, writeOnce: { fd, buffer in
                    Darwin.write(fd, buffer.baseAddress, 7)
                })
            } catch let error as OwnedNativeComputerUseClient.MutationFailure {
                if case .uncertain = error {
                    var prefix = [UInt8](repeating: 0, count: 7)
                    let count = Darwin.read(pipe.fileHandleForReading.fileDescriptor, &prefix, 7)
                    partialBytes = Data(prefix.prefix(max(0, count)))
                }
                throw error
            }
        }
        try admission.begin(at: ContinuousClock.now.advanced(by: inputDelay))
        return try await request(method, params)
    }
    func unpause() { paused = false }
    func releaseOne() { if !gates.isEmpty { gates.removeFirst().resume() } }
    func failNext() { fail = true }
    func corruptClickSchema() { badClick = true }
    private func close() {
        closeCount += 1; let saved = gates; gates.removeAll()
        for gate in saved { gate.resume(throwing: CancellationError()) }
    }
    private func request(_ method: OwnedNativeComputerUseClient.Method, _ params: [String: JSONValue]) async throws -> JSONValue {
        switch method {
        case .initialize: return .object([:])
        case .threadStart: return .object(["thread": .object(["id": .string("owned-synthetic")])])
        case .catalog:
            let shapes: [String: [String: String]] = ["get_app_state": ["app": "string"],
                "click": ["app": "string", "x": badClick ? "string" : "number", "y": "number", "click_count": "integer", "mouse_button": "string"],
                "drag": ["app": "string", "from_x": "number", "from_y": "number", "to_x": "number", "to_y": "number"],
                "press_key": ["app": "string", "key": "string"], "type_text": ["app": "string", "text": "string"]]
            let tools = shapes.mapValues { shape -> JSONValue in
                .object(["type": .string("object"), "additionalProperties": .bool(false),
                    "properties": .object(shape.mapValues { .object(["type": .string($0)]) }),
                    "required": .array(shape.keys.sorted().map(JSONValue.string))])
            }.map { name, schema in (name, JSONValue.object(["name": .string(name), "inputSchema": schema,
                "annotations": .object(["destructiveHint": .bool(false)])])) }
            return .object(["data": .array([.object(["name": .string("relay_native"), "runtimeStatus": .string("connected"),
                "tools": .object(Dictionary(uniqueKeysWithValues: tools))])])])
        case .state:
            calls.append(params)
            if fail { fail = false; throw OwnedNativeComputerUseClient.Failure.timeout }
            if paused { try await withCheckedThrowingContinuation { gates.append($0) } }
            return .object(["content": .array([.object(["type": .string("text"), "text": .string("Owned synthetic receipt")])])])
        }
    }
}
