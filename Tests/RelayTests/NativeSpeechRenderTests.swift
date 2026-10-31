@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import Relay

/// Explicit native integration gate: generates synthetic speech into callbacks only.
/// It never calls speak(), requests consent, records a microphone, stores PCM or plays audio.
@MainActor
struct NativeSpeechRenderTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_NATIVE_SPEECH_RENDER_TEST"] == "1"), .timeLimit(.minutes(1)))
    func installedAppleVoiceRendersBoundedNonSilentPCMWithoutPlayback() async throws {
        let requested = ProcessInfo.processInfo.environment["RELAY_NATIVE_SPEECH_VOICE"]
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.identifier.hasPrefix("com.apple.") && !$0.voiceTraits.contains(.isPersonalVoice)
                && $0.language.lowercased().hasPrefix("en")
        }.sorted { $0.identifier < $1.identifier }
        let candidate = try #require(requested.flatMap { id in candidates.first { $0.identifier == id } } ?? (requested == nil ? candidates.first : nil), "No requested/installed nonpersonal English Apple voice available; no voice download was requested.")
        let voice = try #require(AVSpeechSynthesisVoice(identifier: candidate.identifier), "Selected voice is not installed.")
        #expect(LocalSpeechOutput.isQualifiedVoice(identifier: voice.identifier, isPersonalVoice: voice.voiceTraits.contains(.isPersonalVoice), isAvailableOnDevice: true))
        let synthesizer = AVSpeechSynthesizer()
        defer { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: "Relay local check. One two three.")
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        let observation = SpeechPCMObservation()
        synthesizer.write(utterance) { @Sendable buffer in observation.observe(buffer) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(40))
        while !observation.snapshot().ended, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let result = observation.snapshot()
        #expect(result.ended, "Native synthetic buffer rendering did not finish within40seconds.")
        #expect(result.frames > 0)
        #expect(result.frames <= 4_000_000)
        #expect(result.valid)
        #expect(result.nonSilent, "Generated PCM was entirely silent; no audibility claim is possible.")
        print("Native speech render only: voice=\(voice.identifier), frames=\(result.frames), nonSilent=\(result.nonSilent), terminal=\(result.ended). No playback/microphone/offline claim.")
    }
}

/// Callback owns framework buffer access; only bounded scalar observations leave that thread.
nonisolated private final class SpeechPCMObservation: @unchecked Sendable {
    struct Snapshot: Sendable {
        var frames: UInt64 = 0
        var nonSilent = false
        var valid = true
        var ended = false
    }
    private let lock = NSLock()
    private var value = Snapshot()
    func snapshot() -> Snapshot { lock.withLock { value } }
    func observe(_ audio: AVAudioBuffer) {
        guard let buffer = audio as? AVAudioPCMBuffer else {
            lock.withLock { value.valid = false; value.ended = true }
            return
        }
        let count = Int(buffer.frameLength), channels = Int(buffer.format.channelCount)
        guard count > 0 else { lock.withLock { value.ended = true }; return }
        guard count <= 1_000_000, (1...8).contains(channels),
              buffer.format.sampleRate.isFinite, buffer.format.sampleRate > 0 else {
            lock.withLock { value.valid = false; value.ended = true }
            return
        }
        var finite = true, nonSilent = false
        let stride = buffer.stride
        if let samples = buffer.floatChannelData {
            for channel in 0..<channels {
                for index in 0..<count {
                    let sample = samples[channel][index * stride]
                    finite = finite && sample.isFinite
                    nonSilent = nonSilent || (sample.isFinite && abs(sample) > 0.000_001)
                }
            }
        } else if let samples = buffer.int16ChannelData {
            for channel in 0..<channels {
                for index in 0..<count { nonSilent = nonSilent || samples[channel][index * stride] != 0 }
            }
        } else if let samples = buffer.int32ChannelData {
            for channel in 0..<channels {
                for index in 0..<count { nonSilent = nonSilent || samples[channel][index * stride] != 0 }
            }
        } else { finite = false }
        lock.withLock {
            guard !value.ended else { return }
            value.frames += UInt64(count)
            value.nonSilent = value.nonSilent || nonSilent
            value.valid = value.valid && finite
            if value.frames > 4_000_000 { value.valid = false; value.ended = true }
        }
    }
}
