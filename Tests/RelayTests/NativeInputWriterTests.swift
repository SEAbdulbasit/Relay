import Darwin
import Foundation
import Testing
@testable import Relay

struct NativeInputWriterTests {
    @Test func ownedPipeReceivesExactBytesAndMutableDescriptorFlagsAreRestored() throws {
        let pipe = Pipe(), bytes = Data("{\"synthetic\":\"café 🌍\"}\n".utf8), source = NativeInputRevocation()
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        let descriptor = pipe.fileHandleForWriting.fileDescriptor, flags = fcntl(descriptor, F_GETFL)
        let noSignal = fcntl(descriptor, F_GETNOSIGPIPE)
        try NativeInputWriter.write(bytes, to: descriptor, admission: .init(notAfter: .now.advanced(by: .seconds(2)), revocation: source))
        var received = [UInt8](repeating: 0, count: bytes.count)
        let count = Darwin.read(pipe.fileHandleForReading.fileDescriptor, &received, received.count)
        #expect(count == bytes.count && Data(received) == bytes)
        #expect((fcntl(descriptor, F_GETFL) & (O_NONBLOCK | O_APPEND | O_ASYNC)) == (flags & (O_NONBLOCK | O_APPEND | O_ASYNC)))
        #expect(fcntl(descriptor, F_GETNOSIGPIPE) == noSignal)
    }
    @Test func fullOwnedPipeRefusesWithoutWaitingAndStopNeedsNoIOLock() throws {
        let pipe = Pipe(), source = NativeInputRevocation()
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        let descriptor = pipe.fileHandleForWriting.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        try #require(fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0)
        let fill = [UInt8](repeating: 0x61, count: 4_096)
        var full = false
        for _ in 0..<1_024 {
            let count = fill.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { break }
            try #require(count > 0)
        }
        var single: UInt8 = 0x61
        for _ in 0...4_096 {
            let count = Darwin.write(descriptor, &single, 1)
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { full = true; break }
            try #require(count == 1)
        }
        try #require(full)
        let started = ContinuousClock.now
        do {
            try NativeInputWriter.write(Data([0x62]), to: descriptor,
                admission: .init(notAfter: .now.advanced(by: .seconds(2)), revocation: source))
            Issue.record("The full pipe must not accept new bytes.")
        } catch OwnedNativeComputerUseClient.MutationFailure.notDispatched(let error) {
            #expect(error as? OwnedNativeComputerUseClient.Failure == .transportWrite)
        }
        source.revoke()
        #expect(started.duration(to: .now) < .seconds(1))
    }
    @Test func revokedAdmissionWritesNoBytesAfterActorHop() throws {
        let pipe = Pipe(), source = NativeInputRevocation()
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        let admission = OwnedNativeComputerUseClient.InputAdmission(notAfter: .now.advanced(by: .seconds(2)), revocation: source)
        source.revoke()
        do {
            try NativeInputWriter.write(Data([0x62]), to: pipe.fileHandleForWriting.fileDescriptor, admission: admission)
            Issue.record("Revocation won admission; no write is permitted.")
        } catch OwnedNativeComputerUseClient.MutationFailure.notDispatched(let error) {
            #expect(error as? OwnedNativeComputerUseClient.Failure == .closed)
        }
        let reader = pipe.fileHandleForReading.fileDescriptor, flags = fcntl(reader, F_GETFL)
        try #require(fcntl(reader, F_SETFL, flags | O_NONBLOCK) == 0)
        var byte: UInt8 = 0
        let count = Darwin.read(reader, &byte, 1), readError = errno
        #expect(count == -1 && (readError == EAGAIN || readError == EWOULDBLOCK))
    }

    @Test func partialWriteLeavesATruncatedOwnedStreamAndIsExplicitlyUncertain() throws {
        let pipe = Pipe(), source = NativeInputRevocation(), bytes = Data("{\"synthetic\":\"partial JSON frame\"}\n".utf8)
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        let descriptor = pipe.fileHandleForWriting.fileDescriptor, flags = fcntl(descriptor, F_GETFL)
        let noSignal = fcntl(descriptor, F_GETNOSIGPIPE)
        do {
            try NativeInputWriter.write(bytes, to: descriptor,
                admission: .init(notAfter: .now.advanced(by: .seconds(2)), revocation: source), writeOnce: { fd, buffer in
                    Darwin.write(fd, buffer.baseAddress, 7)
                })
            Issue.record("A partial frame cannot be reported as successful or zero bytes.")
        } catch OwnedNativeComputerUseClient.MutationFailure.uncertain(let error) {
            #expect(error as? OwnedNativeComputerUseClient.Failure == .transportWrite)
        }
        var received = [UInt8](repeating: 0, count: 7)
        #expect(Darwin.read(pipe.fileHandleForReading.fileDescriptor, &received, 7) == 7)
        #expect(Data(received) == bytes.prefix(7) && received.last != 0x0A)
        #expect((fcntl(descriptor, F_GETFL) & (O_NONBLOCK | O_APPEND | O_ASYNC)) == (flags & (O_NONBLOCK | O_APPEND | O_ASYNC)))
        #expect(fcntl(descriptor, F_GETNOSIGPIPE) == noSignal)
    }

    @Test func cancellationBeforeAdmissionWritesNothingWithoutWaitingForScheduledStop() async throws {
        let source = NativeInputRevocation()
        let admission = OwnedNativeComputerUseClient.InputAdmission(notAfter: .now.advanced(by: .seconds(2)), revocation: source)
        let task = Task { () throws -> Bool in
            let pipe = Pipe()
            defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
            // Cancel this exact task synchronously; no Stop/revocation callback is scheduled.
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try NativeInputWriter.write(Data([0x62]), to: pipe.fileHandleForWriting.fileDescriptor, admission: admission)
                Issue.record("Already-visible cancellation must refuse input admission.")
                return false
            } catch OwnedNativeComputerUseClient.MutationFailure.notDispatched(let error) {
                #expect(error is CancellationError)
                let reader = pipe.fileHandleForReading.fileDescriptor, flags = fcntl(reader, F_GETFL)
                try #require(fcntl(reader, F_SETFL, flags | O_NONBLOCK) == 0)
                var byte: UInt8 = 0
                let count = Darwin.read(reader, &byte, 1), readError = errno
                return count == -1 && (readError == EAGAIN || readError == EWOULDBLOCK)
            }
        }
        #expect(try await task.value)
        let now = ContinuousClock.now
        // The refusal came from task cancellation, not a hidden Stop/revocation side effect.
        #expect(source.ticket().admit(now: now, notAfter: now.advanced(by: .seconds(1))) == .admitted)
    }
}
