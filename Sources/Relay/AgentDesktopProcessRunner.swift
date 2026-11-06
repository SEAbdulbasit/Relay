import Darwin
import Foundation

/// All mutable process state is confined to `queue`. Both pipes are drained in
/// nonblocking chunks, so neither can stall the child while the other is read.
nonisolated final class AgentDesktopProcessRunner: @unchecked Sendable {
    nonisolated struct Output: Sendable {
        let stdout: Data
        let stderr: Data
        let exitStatus: Int32
    }

    private let queue = DispatchQueue(label: "dev.relay.agent-desktop-process")
    private let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private var capturedOut = Data()
    private var capturedErr = Data()
    private var continuation: CheckedContinuation<Output, any Error>?
    private var timer: DispatchSourceTimer?
    private var cancelled = false
    private var failure: (any Error)?
    private var terminateAt: DispatchTime?
    private var deadline = DispatchTime.now()
    private let outputLimit: Int

    private init(executable: URL, arguments: [String], environment: [String: String]?, outputLimit: Int) {
        self.outputLimit = max(1, outputLimit)
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr
    }

    static func run(executable: URL, arguments: [String], environment: [String: String]? = nil,
                    timeoutSeconds: TimeInterval = 8, outputLimit: Int = 1_048_576) async throws -> Output {
        let runner = AgentDesktopProcessRunner(executable: executable, arguments: arguments,
                                              environment: environment, outputLimit: outputLimit)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                runner.queue.async { runner.start(continuation, timeoutSeconds: timeoutSeconds) }
            }
        } onCancel: {
            runner.queue.async { runner.cancelled = true }
        }
    }

    private func start(_ continuation: CheckedContinuation<Output, any Error>, timeoutSeconds: TimeInterval) {
        self.continuation = continuation
        guard !cancelled else { finish(error: CancellationError()); return }
        for pipe in [stdout, stderr] {
            let descriptor = pipe.fileHandleForReading.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                finish(error: RelayError.message("Unable to configure agent-desktop output pipes.")); return
            }
        }
        do { try process.run() } catch { finish(error: error); return }
        deadline = .now() + max(0.01, timeoutSeconds)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [self] in poll() }
        self.timer = timer
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.resume()
    }

    private func drain(_ pipe: Pipe, into data: inout Data) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        // Bound each polling turn so cancellation cannot be starved by output.
        for _ in 0..<32 {
            let count = read(pipe.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
            if count <= 0 { break }
            let remaining = outputLimit - data.count
            data.append(contentsOf: buffer.prefix(min(count, remaining)))
            if count > remaining {
                failure = RelayError.message("agent-desktop output exceeded its bounded capture limit. Action effects are uncertain; observe before retrying.")
                break
            }
        }
    }

    private func poll() {
        drain(stdout, into: &capturedOut)
        drain(stderr, into: &capturedErr)
        if cancelled { failure = CancellationError() }
        if DispatchTime.now() >= deadline, failure == nil {
            failure = RelayError.message("agent-desktop timed out. Action effects are uncertain; observe before retrying.")
        }
        if process.isRunning {
            if failure != nil {
                if let terminateAt {
                    if DispatchTime.now() >= terminateAt { _ = kill(process.processIdentifier, SIGKILL) }
                } else {
                    process.terminate()
                    terminateAt = .now() + .milliseconds(200)
                }
            }
            return
        }
        // Drain the bounded remainder after exit without waiting for EOF from
        // any helper that might have inherited a write descriptor.
        for _ in 0..<5 {
            drain(stdout, into: &capturedOut)
            drain(stderr, into: &capturedErr)
        }
        finish(error: failure)
    }

    private func finish(error: (any Error)?) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        for pipe in [stdout, stderr] {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: Output(stdout: capturedOut, stderr: capturedErr, exitStatus: process.terminationStatus)) }
    }
}
