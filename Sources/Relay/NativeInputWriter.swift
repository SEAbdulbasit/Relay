import Darwin
import Foundation

/// One bounded nonblocking attempt. Never waits for helper stdin, never retries a partial
/// message, and never holds the revocation lock while writing. Only the owned pipe is used.
nonisolated enum NativeInputWriter {
    static func write(_ bytes: Data, to descriptor: Int32,
                      admission: OwnedNativeComputerUseClient.InputAdmission,
                      writeOnce: (Int32, UnsafeRawBufferPointer) -> Int = { Darwin.write($0, $1.baseAddress, $1.count) }) throws {
        typealias Failure = OwnedNativeComputerUseClient.Failure
        typealias MutationFailure = OwnedNativeComputerUseClient.MutationFailure
        guard !bytes.isEmpty, bytes.count <= 16_384 else { throw MutationFailure.notDispatched(Failure.outputLimit) }
        let flags = fcntl(descriptor, F_GETFL), noSignal = fcntl(descriptor, F_GETNOSIGPIPE)
        guard flags >= 0, noSignal >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw MutationFailure.notDispatched(Failure.transportWrite)
        }
        defer { _ = fcntl(descriptor, F_SETFL, flags) }
        guard fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else { throw MutationFailure.notDispatched(Failure.transportWrite) }
        defer { _ = fcntl(descriptor, F_SETNOSIGPIPE, noSignal) }
        try admission.begin()
        let count = bytes.withUnsafeBytes { writeOnce(descriptor, $0) }
        if count <= 0 { throw MutationFailure.notDispatched(Failure.transportWrite) }
        guard count == bytes.count else { throw MutationFailure.uncertain(Failure.transportWrite) }
    }
}
