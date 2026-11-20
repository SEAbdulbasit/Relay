import AppKit
import CoreGraphics
import Foundation
import IOKit
import IOKit.hid
import Observation
import simd
import SwiftUI

// MARK: - Notch Preferences & Calibration Profile

nonisolated enum PhysicalTapSensitivity: String, CaseIterable, Codable, Identifiable, Sendable {
    case gentle
    case standard
    case firm

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gentle: "Gentle"
        case .standard: "Standard"
        case .firm: "Firm"
        }
    }

    var threshold: Double {
        switch self {
        case .gentle: 0.7
        case .standard: 1.1
        case .firm: 2.0
        }
    }
}

nonisolated enum PhysicalTapAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case close
    case takeOver
    case magicReply
    case summarize
    case proofread

    var id: String { rawValue }

    var label: String {
        switch self {
        case .close: "Close notch"
        case .takeOver: "Take Over"
        case .magicReply: "Magic Reply"
        case .summarize: "Summarize"
        case .proofread: "Proofread"
        }
    }
}

nonisolated struct PhysicalTapCalibrationProfile: Codable, Equatable, Sendable {
    let version: Int
    let date: Date
    let sensitivities: [String]
    let baselineLux: Double

    var isValid: Bool {
        version == 1
            && !sensitivities.isEmpty
            && baselineLux.isFinite
            && baselineLux > 0.25
            && sensitivities.allSatisfy { ["gentle", "standard", "firm"].contains($0) }
    }
}

nonisolated enum NotchPreferences {
    static let clickEnabledKey = "relay.sidekick.notchClickEnabled"
    static let externalBarEnabledKey = "relay.sidekick.externalBarEnabled"
    static let compactModeKey = "relay.sidekick.compactStatus"
    static let physicalTapEnabledKey = "relay.sidekick.physicalTapEnabled"
    static let secondPhysicalTapKey = "relay.sidekick.secondPhysicalTap"
    static let physicalTapSensitivityKey = "relay.sidekick.physicalTapSensitivity"
    static let physicalTapCalibrationKey = "relay.sidekick.physicalTapCalibration.v1"

    static func calibration(in defaults: UserDefaults = .standard) -> PhysicalTapCalibrationProfile? {
        guard let data = defaults.data(forKey: physicalTapCalibrationKey),
              let profile = try? JSONDecoder().decode(PhysicalTapCalibrationProfile.self, from: data),
              profile.isValid else {
            return nil
        }
        return profile
    }

    static func physicalTapEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: physicalTapEnabledKey) as? Bool ?? true
    }

    static func setPhysicalTapEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: physicalTapEnabledKey)
        NotificationCenter.default.post(name: .physicalNotchTapChanged, object: nil)
    }

    static func secondPhysicalTap(in defaults: UserDefaults = .standard) -> PhysicalTapAction {
        PhysicalTapAction(rawValue: defaults.string(forKey: secondPhysicalTapKey) ?? "") ?? .close
    }

    static func setSecondPhysicalTap(_ action: PhysicalTapAction, in defaults: UserDefaults = .standard) {
        defaults.set(action.rawValue, forKey: secondPhysicalTapKey)
        NotificationCenter.default.post(name: .physicalNotchTapChanged, object: nil)
    }

    static func sensitivity(in defaults: UserDefaults = .standard) -> PhysicalTapSensitivity {
        PhysicalTapSensitivity(rawValue: defaults.string(forKey: physicalTapSensitivityKey) ?? "") ?? .standard
    }

    static func setSensitivity(_ sensitivity: PhysicalTapSensitivity, in defaults: UserDefaults = .standard) {
        defaults.set(sensitivity.rawValue, forKey: physicalTapSensitivityKey)
        NotificationCenter.default.post(name: .physicalNotchTapChanged, object: nil)
    }

    static func physicalTapThreshold(in defaults: UserDefaults = .standard) -> Double {
        threshold(for: defaults.string(forKey: physicalTapSensitivityKey) ?? "standard")
    }

    static func threshold(for sensitivity: String) -> Double {
        switch sensitivity {
        case "gentle": 0.7
        case "firm": 2.0
        default: 1.1
        }
    }

    static func clickEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: clickEnabledKey) as? Bool ?? true
    }

    static func externalBarEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: externalBarEnabledKey) as? Bool ?? true
    }

    static func resetAll(in defaults: UserDefaults = .standard) {
        for key in [
            clickEnabledKey,
            externalBarEnabledKey,
            physicalTapEnabledKey,
            secondPhysicalTapKey,
            physicalTapSensitivityKey,
            physicalTapCalibrationKey
        ] {
            defaults.removeObject(forKey: key)
        }
        NotificationCenter.default.post(name: .physicalNotchTapChanged, object: nil)
    }
}

extension Notification.Name {
    nonisolated static let notchInteractionChanged = Notification.Name("relay.sidekick.notchInteractionChanged")
    nonisolated static let notchAppearanceChanged = Notification.Name("relay.sidekick.notchAppearanceChanged")
    nonisolated static let physicalNotchTapChanged = Notification.Name("relay.sidekick.physicalNotchTapChanged")
}

// MARK: - Multi-Sensor Physical Tap Detector (ALS + Accel + Gyro + Lid Guard)

nonisolated struct PhysicalTapDetector: Sendable {
    var sensitivity: Double = 1.1
    private var lastTime = -Double.infinity
    private var lastAcceptedTap = -Double.infinity
    private var history: [(time: Double, lux: Double)] = []
    private var candidate: OpticalPulse?
    private var acceleration = PhysicalTapMotionBand()
    private var rotation = PhysicalTapMotionBand()
    private var accelerationTime = -Double.infinity
    private var rotationTime = -Double.infinity
    private var accelerationPulse = -Double.infinity
    private var rotationPulse = -Double.infinity
    private var motionEvidence: [Double] = []

    private nonisolated struct OpticalPulse: Sendable {
        let start: Double
        let baseline: Double
        var minimum: Double
        var minimumTime: Double
    }

    init(sensitivity: Double = 1.1) {
        self.sensitivity = sensitivity
    }

    mutating func reset(at time: Double) {
        self = Self(sensitivity: sensitivity)
    }

    mutating func accel(_ value: SIMD3<Double>, at time: Double) {
        guard valid(value), time.isFinite, time > accelerationTime else { return }
        if time - accelerationTime >= 0.08 {
            clearPendingTap()
            history.removeAll(keepingCapacity: true)
        }
        accelerationTime = time
        if let evidence = acceleration.add(value, at: time),
           evidence.rms >= max(0.0011, evidence.noise * 1.8) * motionScale,
           evidence.cancellation < 0.8 {
            accelerationPulse = time
            rememberMotion(at: time)
        }
    }

    mutating func gyro(_ value: SIMD3<Double>, at time: Double) {
        guard valid(value), time.isFinite, time > rotationTime else { return }
        if time - rotationTime >= 0.08 {
            clearPendingTap()
            history.removeAll(keepingCapacity: true)
        }
        rotationTime = time
        if let evidence = rotation.add(value, at: time),
           evidence.rms >= max(0.145, evidence.noise * 1.5) * motionScale,
           evidence.cancellation < 0.8 {
            rotationPulse = time
            rememberMotion(at: time)
        }
    }

    private var motionScale: Double { min(1.8, max(0.85, sensitivity / 1.1)) }

    private mutating func rememberMotion(at time: Double) {
        guard abs(accelerationPulse - rotationPulse) <= 0.06 else { return }
        motionEvidence.removeAll { time - $0 > 1.5 }
        if time - (motionEvidence.last ?? -.infinity) >= 0.01 {
            motionEvidence.append(time)
        }
    }

    private mutating func clearPendingTap() {
        candidate = nil
        motionEvidence.removeAll(keepingCapacity: true)
        accelerationPulse = -.infinity
        rotationPulse = -.infinity
    }

    private func valid(_ value: SIMD3<Double>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }

    /// Only an ambient-light dip corroborated by nearby accel+gyro impulses emits a tap.
    mutating func light(_ lux: Double, at time: Double) -> Bool {
        guard time.isFinite, time > lastTime else { return false }
        let gap = time - lastTime
        lastTime = time
        guard lux.isFinite, lux >= 0 else {
            clearPendingTap()
            history.removeAll(keepingCapacity: true)
            return false
        }
        if gap > 0.65 {
            clearPendingTap()
            history.removeAll(keepingCapacity: true)
        }

        motionEvidence.removeAll { time - $0 > 1.5 }
        guard time - accelerationTime < 0.1, time - rotationTime < 0.1 else {
            clearPendingTap()
            history.removeAll(keepingCapacity: true)
            return false
        }
        if var pulse = candidate {
            if lux < pulse.minimum {
                pulse.minimum = lux
                pulse.minimumTime = time
            }
            if time - pulse.start > 0.9 {
                candidate = nil
                history.removeAll(keepingCapacity: true)
                history.append((time, lux))
                return false
            }
            if lux >= pulse.minimum + (pulse.baseline - pulse.minimum) * 0.6 {
                let corroborated = motionEvidence.contains {
                    $0 >= pulse.start - 0.3 && $0 <= pulse.minimumTime + 0.15
                }
                clearPendingTap()
                remember(lux, at: time)
                guard corroborated, time - lastAcceptedTap >= 0.3 else { return false }
                lastAcceptedTap = time
                return true
            }
            candidate = pulse
            return false
        }

        history.removeAll { time - $0.time > 1 }
        if !history.isEmpty {
            let recent = history.suffix(2)
            let baseline = recent.reduce(0.0) { $0 + $1.lux } / Double(recent.count)
            let scale = min(1.5, max(0.9, sensitivity / 1.1))
            let requiredDrop = max(0.08, baseline * 0.17 * scale)
            if baseline > 0.25 && baseline - lux >= requiredDrop {
                candidate = OpticalPulse(start: time, baseline: baseline, minimum: lux, minimumTime: time)
                return false
            }
        }
        remember(lux, at: time)
        return false
    }

    private mutating func remember(_ lux: Double, at time: Double) {
        history.append((time, lux))
        if history.count > 5 { history.removeFirst(history.count - 5) }
    }
}

private nonisolated struct PhysicalTapMotionBand: Sendable {
    nonisolated struct Evidence: Sendable {
        let rms: Double
        let cancellation: Double
        let noise: Double
    }

    private var baseline: SIMD3<Double>?
    private var previousTime: Double?
    private var windowStart = 0.0
    private var vectorSum = SIMD3<Double>.zero
    private var energy = 0.0
    private var count = 0
    private var previousSum = SIMD3<Double>.zero
    private var previousEnergy = 0.0
    private var previousCount = 0
    private var noiseSamples: [Double] = []
    private var noiseIndex = 0
    private var noise = 0.0
    private var noiseUpdated = 0.0

    mutating func add(_ value: SIMD3<Double>, at time: Double) -> Evidence? {
        guard let before = previousTime, let baseline, time > before, time - before < 0.08 else {
            self = Self()
            self.baseline = value
            previousTime = time
            windowStart = time
            return nil
        }
        let delta = time - before
        let high = value - baseline
        self.baseline = baseline + high * (1 - exp(-delta / 0.012))
        previousTime = time
        vectorSum += high
        energy += high.x * high.x + high.y * high.y + high.z * high.z
        count += 1
        guard time - windowStart >= 0.01 else { return nil }
        let sampleCount = Double(count + previousCount)
        let rms = sqrt((energy + previousEnergy) / max(1, sampleCount))
        let vector = vectorSum + previousSum
        let cancellation = sqrt(vector.x * vector.x + vector.y * vector.y + vector.z * vector.z)
            / max(1e-12, sampleCount * rms)
        previousSum = vectorSum
        previousEnergy = energy
        previousCount = count
        vectorSum = .zero
        energy = 0
        count = 0
        windowStart = time
        if noiseSamples.count < 512 {
            noiseSamples.append(rms)
        } else {
            noiseSamples[noiseIndex] = rms
            noiseIndex = (noiseIndex + 1) % 512
        }
        if time - noiseUpdated >= 0.25, noiseSamples.count >= 25 {
            noise = noiseSamples.sorted()[noiseSamples.count / 5]
            noiseUpdated = time
        }
        return Evidence(rms: rms, cancellation: cancellation, noise: noise)
    }
}

nonisolated enum PhysicalTapReport {
    static func vector(_ bytes: UnsafeBufferPointer<UInt8>) -> SIMD3<Double>? {
        guard bytes.count == 22 else { return nil }
        func read(_ offset: Int) -> Double {
            let bits = UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
            return Double(Int32(bitPattern: bits)) / 65_536
        }
        return SIMD3(read(6), read(10), read(14))
    }

    static func lux(_ bytes: UnsafeBufferPointer<UInt8>) -> Double? {
        guard bytes.count == 122 else { return nil }
        let bits = UInt32(bytes[40])
            | (UInt32(bytes[41]) << 8)
            | (UInt32(bytes[42]) << 16)
            | (UInt32(bytes[43]) << 24)
        let value = Double(Float(bitPattern: bits))
        return value.isFinite && value >= 0 ? value : nil
    }
}

nonisolated struct PhysicalTapLidGuard: Sendable {
    private(set) var blockedUntil = Double.infinity
    private var referenceAngle: Double?
    private var lastReadingTime = -Double.infinity
    private static let settleDuration = 3.0
    private static let movementThreshold = 0.75

    init() {}

    mutating func reset(at time: Double) {
        referenceAngle = nil
        lastReadingTime = -.infinity
        blockedUntil = time + Self.settleDuration
    }

    mutating func update(angle: Double?, at time: Double) {
        guard time.isFinite, time > lastReadingTime else { return }
        let gap = time - lastReadingTime
        lastReadingTime = time
        guard let angle, angle.isFinite, (20...180).contains(angle) else {
            referenceAngle = nil
            blockedUntil = time + Self.settleDuration
            return
        }
        guard let previous = referenceAngle else {
            referenceAngle = angle
            blockedUntil = time + Self.settleDuration
            return
        }
        if gap > 0.5 || abs(angle - previous) >= Self.movementThreshold {
            referenceAngle = angle
            blockedUntil = time + Self.settleDuration
        }
    }

    func allowsTap(at time: Double) -> Bool {
        time.isFinite && referenceAngle != nil && time >= blockedUntil && time - lastReadingTime <= 0.5
    }
}

// MARK: - Missed-Tap Discovery Hint Detector (Motion Motif Only — Never Activates Input)

nonisolated struct PhysicalMissedTapDetector: Sendable {
    private var gyroBase: SIMD3<Double>?
    private var accelBase: SIMD3<Double>?
    private var gyroTime = -Double.infinity
    private var accelTime = -Double.infinity
    private var accelHigh = SIMD3<Double>.zero
    private var noise = 0.12
    private var impactEnergy = 0.0
    private var impactPeak = 0.0
    private var impactValley = 0.0
    private var previousImpact = 0.0
    private var impactArmed = true
    private var candidate: Pulse?
    private var sequence: [Signature] = []
    private var strongSequence: [Signature] = []

    private nonisolated struct Pulse: Sendable {
        let start: Double
        var peak: Double
        var axis: SIMD3<Double>
        var opposite = 0.0
        var gyroEnergy = SIMD3<Double>.zero
        var accelEnergy = SIMD3<Double>.zero
        var onsetAccelEnergy = SIMD3<Double>.zero
        var accelPeak = 0.0
        var tailEnergy = 0.0
        var tailSamples = 0
    }

    private nonisolated struct Signature: Sendable {
        let time: Double
        let axis: SIMD3<Double>
        let peak: Double
    }

    init() {}

    static func keyboardActive(downAge: Double, upAge: Double, modifierAge: Double, keyHeld: Bool = false) -> Bool {
        guard downAge.isFinite, upAge.isFinite, modifierAge.isFinite,
              downAge >= 0, upAge >= 0, modifierAge >= 0 else { return true }
        return keyHeld || min(downAge, upAge, modifierAge) < 1
    }

    mutating func clearSequence() {
        candidate = nil
        sequence.removeAll(keepingCapacity: true)
        strongSequence.removeAll(keepingCapacity: true)
    }

    mutating func reset() {
        self = Self()
    }

    mutating func accel(_ value: SIMD3<Double>, at time: Double) {
        guard valid(value), time.isFinite, time > accelTime else { return }
        let dt = time - accelTime
        accelTime = time
        guard dt < 0.08, let base = accelBase else {
            accelBase = value
            accelHigh = .zero
            clearSequence()
            return
        }
        accelHigh = value - base
        accelBase = base + accelHigh * (1 - exp(-dt / 0.012))
        if var pulse = candidate {
            pulse.accelEnergy += accelHigh * accelHigh
            if time - pulse.start <= 0.025 { pulse.onsetAccelEnergy += accelHigh * accelHigh }
            pulse.accelPeak = max(pulse.accelPeak, length(accelHigh))
            candidate = pulse
        }
    }

    mutating func rotation(_ value: SIMD3<Double>, at time: Double, inputActive: Bool) -> Bool {
        guard valid(value), time.isFinite, time > gyroTime else { return false }
        let dt = time - gyroTime
        gyroTime = time
        guard dt < 0.08, let base = gyroBase else {
            gyroBase = value
            clearSequence()
            return false
        }
        let high = value - base
        gyroBase = base + high * (1 - exp(-dt / 0.012))
        let magnitude = length(high)
        let power = magnitude * magnitude
        impactEnergy += (power - impactEnergy) * (1 - exp(-dt / (power > impactEnergy ? 0.002 : 0.022)))
        let envelope = sqrt(max(0, impactEnergy))
        impactPeak = max(impactPeak, envelope)
        if !impactArmed && envelope < max(noise * 1.5, impactPeak * 0.4) {
            impactArmed = true
            impactValley = envelope
        }
        if impactArmed { impactValley = min(impactValley, envelope) }
        let freshAttack = impactArmed && envelope > previousImpact * 1.025 && envelope > impactValley * 1.8
        previousImpact = envelope
        guard !inputActive, time - accelTime < 0.05 else {
            clearSequence()
            return false
        }
        sequence.removeAll { time - $0.time > 6.5 }
        strongSequence.removeAll { time - $0.time > 6.5 }
        if var pulse = candidate {
            if magnitude > pulse.peak {
                pulse.peak = magnitude
                pulse.axis = high / max(magnitude, 1e-12)
            }
            pulse.opposite = max(pulse.opposite, -dot(high, pulse.axis))
            pulse.gyroEnergy += high * high
            if time - pulse.start >= 0.065 {
                pulse.tailEnergy += magnitude * magnitude
                pulse.tailSamples += 1
            }
            if time - pulse.start < 0.13 {
                candidate = pulse
                return false
            }
            candidate = nil
            let gyroTotal = sum(pulse.gyroEnergy), accelTotal = sum(pulse.accelEnergy)
            guard gyroTotal > 0, accelTotal > 0 else { return false }
            let verticalFraction = pulse.accelEnergy.z / accelTotal
            let onsetVertical = pulse.onsetAccelEnergy.z / max(1e-12, sum(pulse.onsetAccelEnergy))
            let yawFraction = pulse.gyroEnergy.z / gyroTotal
            let tail = sqrt(pulse.tailEnergy / Double(max(1, pulse.tailSamples))) / pulse.peak
            let reversing = pulse.opposite / pulse.peak
            let ordinary = pulse.peak >= 0.8 && pulse.accelPeak >= 0.003 && pulse.accelPeak < 0.5
                && reversing >= 0.4 && tail < 0.55 && yawFraction < 0.08
                && (verticalFraction > 0.60 || onsetVertical > 0.70)
            let strong = pulse.peak >= 3 && pulse.accelPeak >= 0.04 && pulse.accelPeak < 1
                && reversing >= 0.25 && tail < 0.85 && yawFraction < 0.18 && verticalFraction > 0.60
            let signature = Signature(time: pulse.start, axis: pulse.axis, peak: pulse.peak)
            let followsContact = sequence.last.map { last in
                pulse.start - last.time <= 3 && pulse.start - last.time >= 0.16
                    && abs(dot(signature.axis, last.axis)) >= 0.90
                    && (0.25...4.0).contains(signature.peak / last.peak)
            } ?? false
            let overlapping = followsContact && pulse.peak >= 0.8 && pulse.accelPeak >= 0.003
                && pulse.accelPeak < 0.5 && reversing >= 0.30 && tail < 0.60 && yawFraction < 0.25
            let normalMatch = (ordinary || overlapping) && Self.append(signature, to: &sequence, alignment: 0.90, strength: 0.25...4.0)
            let strongMatch = strong && Self.append(signature, to: &strongSequence, alignment: 0.80, strength: 0.2...5)
            if normalMatch || strongMatch {
                sequence.removeAll(keepingCapacity: true)
                strongSequence.removeAll(keepingCapacity: true)
                return true
            }
        } else if freshAttack && magnitude >= max(0.8, noise * 5) {
            impactArmed = false
            impactPeak = envelope
            candidate = Pulse(
                start: time,
                peak: magnitude,
                axis: high / max(magnitude, 1e-12),
                gyroEnergy: high * high,
                accelEnergy: accelHigh * accelHigh,
                onsetAccelEnergy: accelHigh * accelHigh,
                accelPeak: length(accelHigh)
            )
        } else {
            noise += (min(magnitude, noise * 2 + 0.02) - noise) * min(1, dt / 2)
        }
        return false
    }

    private static func append(
        _ signature: Signature,
        to sequence: inout [Signature],
        alignment: Double,
        strength: ClosedRange<Double>
    ) -> Bool {
        if let last = sequence.last {
            let gap = signature.time - last.time
            if gap < 0.16 { return false }
            let cosAngle = abs(
                signature.axis.x * last.axis.x
                + signature.axis.y * last.axis.y
                + signature.axis.z * last.axis.z
            )
            if gap > 3 || cosAngle < alignment || !strength.contains(signature.peak / last.peak) {
                sequence.removeAll(keepingCapacity: true)
            }
        }
        sequence.append(signature)
        return sequence.count >= 3
    }

    private func sum(_ v: SIMD3<Double>) -> Double { v.x + v.y + v.z }
    private func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { sum(a * b) }
    private func length(_ v: SIMD3<Double>) -> Double { sqrt(dot(v, v)) }
    private func valid(_ v: SIMD3<Double>) -> Bool { v.x.isFinite && v.y.isFinite && v.z.isFinite }
}

// MARK: - Calibration Sample Capture & Evaluation

nonisolated struct PhysicalTapSample: Sendable {
    nonisolated enum Kind: Sendable { case acceleration, rotation, light, lid }
    let kind: Kind
    let time: Double
    let value: SIMD3<Double>
}

nonisolated final class PhysicalTapCalibrationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [PhysicalTapSample] = []
    private var overflowed = false

    init() {}

    func append(_ sample: PhysicalTapSample) {
        lock.lock()
        defer { lock.unlock() }
        guard samples.count < 120_000 else {
            overflowed = true
            return
        }
        samples.append(sample)
    }

    func take() -> [PhysicalTapSample]? {
        lock.lock()
        defer {
            samples.removeAll()
            overflowed = false
            lock.unlock()
        }
        return overflowed ? nil : samples
    }
}

nonisolated enum PhysicalTapCalibrationEvaluation {
    nonisolated struct Trial: Sendable {
        nonisolated enum Kind: Sendable { case quiet, tap, fingerPass }
        let kind: Kind
        let start: Double
        let end: Double
    }

    nonisolated struct Result: Sendable {
        let profile: PhysicalTapCalibrationProfile?
        let message: String
    }

    static func evaluate(samples: [PhysicalTapSample], trials: [Trial]) -> Result {
        guard let quiet = trials.first, quiet.kind == .quiet, quiet.end - quiet.start >= 4.5,
              trials.filter({ $0.kind == .tap }).count == 5,
              trials.filter({ $0.kind == .fingerPass }).count == 2,
              let end = trials.last?.end,
              zip(trials, trials.dropFirst()).allSatisfy({ $0.end <= $1.start }) else {
            return Result(profile: nil, message: "The calibration was interrupted. Start again when you’re ready.")
        }
        let recording = samples.filter { $0.time >= quiet.start && $0.time <= end }
        for kind in [PhysicalTapSample.Kind.acceleration, .rotation, .light, .lid] {
            let stream = recording.filter { $0.kind == kind }.sorted { $0.time < $1.time }
            let gap = kind == .light ? 0.65 : kind == .lid ? 0.5 : 0.08
            guard let first = stream.first, let last = stream.last,
                  first.time - quiet.start <= gap, end - last.time <= gap,
                  stream.allSatisfy({ $0.value.x.isFinite && $0.value.y.isFinite && $0.value.z.isFinite }),
                  zip(stream, stream.dropFirst()).allSatisfy({ $1.time - $0.time <= gap }) else {
                return Result(profile: nil, message: "A sensor stopped reporting. Keep your Mac awake and try again.")
            }
        }
        let angles = recording.filter { $0.kind == .lid }.map { $0.value.x }
        guard angles.allSatisfy({ (20...180).contains($0) }),
              (angles.max() ?? 0) - (angles.min() ?? 0) < 0.75 else {
            return Result(profile: nil, message: "The lid moved during calibration. Let it settle, then try again.")
        }
        let light = recording.filter { $0.kind == .light }
        let baseline = light.filter { $0.time < quiet.end }.map { $0.value.x }.sorted()
        guard !baseline.isEmpty, baseline[baseline.count / 2] > 0.25,
              light.allSatisfy({ $0.value.x >= 0 }) else {
            return Result(profile: nil, message: "There’s too little light to recognize touch reliably. Try a brighter spot.")
        }
        let baselineLux = baseline[baseline.count / 2]
        let baselineRange = (baseline.last! - baseline.first!) / baselineLux
        guard baselineRange < 0.15 else {
            return Result(profile: nil, message: "The light changed during the quiet baseline. Try again with steady lighting.")
        }
        for trial in trials where trial.kind == .fingerPass {
            let values = light.filter { $0.time >= trial.start && $0.time < trial.end }.map { $0.value.x }
            guard let minimum = values.min(), let maximum = values.max(), maximum > 0.25,
                  (maximum - minimum) / maximum >= 0.08 else {
                return Result(profile: nil, message: "The sensor didn’t see both finger passes. Move your finger directly across the tap spot, without touching the screen.")
            }
        }
        var validated: [String] = []
        for name in ["gentle", "standard", "firm"] {
            let threshold = NotchPreferences.threshold(for: name)
            if [threshold, threshold * 0.9].allSatisfy({ sensitivity in
                let hits = detections(samples: recording, sensitivity: sensitivity)
                let taps = trials.filter { $0.kind == .tap }
                return hits.count == taps.count && taps.allSatisfy { trial in
                    hits.filter { $0 >= trial.start && $0 < trial.end }.count == 1
                }
            }) {
                validated.append(name)
            }
        }
        guard !validated.isEmpty else {
            return Result(
                profile: nil,
                message: "Your taps and finger passes weren’t distinct enough to save new tuning. Try again with your Mac in its usual position and tap directly over the marked spot."
            )
        }
        return Result(
            profile: PhysicalTapCalibrationProfile(
                version: 1,
                date: Date(),
                sensitivities: validated,
                baselineLux: baselineLux
            ),
            message: "All five taps were recognized, and the quiet baseline and both finger passes were rejected. Your personalized sensitivity is ready."
        )
    }

    private static func detections(samples: [PhysicalTapSample], sensitivity: Double) -> [Double] {
        var detector = PhysicalTapDetector(sensitivity: sensitivity)
        var hits: [Double] = []
        for sample in samples {
            switch sample.kind {
            case .acceleration: detector.accel(sample.value, at: sample.time)
            case .rotation: detector.gyro(sample.value, at: sample.time)
            case .light:
                if detector.light(sample.value.x, at: sample.time) { hits.append(sample.time) }
            case .lid: break
            }
        }
        return hits
    }
}

// MARK: - IOKit SPU HID Sensor Worker

nonisolated enum PhysicalTapClock {
    static let scale: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    static var now: Double {
        Double(mach_absolute_time()) * scale
    }
}

private nonisolated let physicalTapHIDReportCallback: IOHIDReportWithTimeStampCallback = { context, result, _, _, _, report, length, stamp in
    guard result == kIOReturnSuccess, let context else { return }
    let stream = Unmanaged<PhysicalTapSensor.StreamBox>.fromOpaque(context).takeUnretainedValue()
    let bytes = UnsafeBufferPointer(start: report, count: length)
    let time = Double(stamp) * PhysicalTapClock.scale
    if stream.usage == 4 {
        if let lux = PhysicalTapReport.lux(bytes) {
            stream.owner?.receiveLight(lux, at: time)
        }
    } else if let vector = PhysicalTapReport.vector(bytes) {
        stream.owner?.receiveMotion(usage: stream.usage, value: vector, at: time)
    }
}

nonisolated final class PhysicalTapSensor: @unchecked Sendable {
    nonisolated enum Status: String, Sendable, Equatable {
        case starting
        case ready
        case settling
        case unavailable
        case stalled
        case stopped
    }

    nonisolated final class StreamBox {
        let device: IOHIDDevice
        let usage: Int
        weak var owner: PhysicalTapSensor?
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 128)

        init(device: IOHIDDevice, usage: Int, owner: PhysicalTapSensor) {
            self.device = device
            self.usage = usage
            self.owner = owner
        }

        deinit {
            buffer.deallocate()
        }
    }

    let onTap: @Sendable (Double, UInt64) -> Void
    let onStatus: @Sendable (Status, UInt64) -> Void
    private let onMissedTapHint: (@Sendable (UInt64) -> Void)?
    private let onSample: (@Sendable (PhysicalTapSample) -> Void)?

    private let lock = NSCondition()
    private var wanted = false
    private var running = false
    private var generation: UInt64 = 0
    private var sensitivity = 1.1
    private var eligible = false
    private var eligibleSince = Double.infinity
    private var eligibilityCheckedAt = -Double.infinity

    private var detector = PhysicalTapDetector()
    private var missedTapDetector = PhysicalMissedTapDetector()
    private var streams: [StreamBox] = []
    private var driverIntervals: [(io_service_t, CFTypeRef)] = []
    private var lidDevice: IOHIDDevice?
    private var lidGuard = PhysicalTapLidGuard()
    private var streamGeneration: UInt64 = 0
    private var streamStarted = 0.0
    private var lastAccel = 0.0
    private var lastGyro = 0.0
    private var lastLight = 0.0
    private var receivedAccel = false
    private var receivedGyro = false
    private var receivedLight = false

    init(
        onTap: @escaping @Sendable (Double, UInt64) -> Void,
        onStatus: @escaping @Sendable (Status, UInt64) -> Void,
        onMissedTapHint: (@Sendable (UInt64) -> Void)? = nil,
        onSample: (@Sendable (PhysicalTapSample) -> Void)? = nil
    ) {
        self.onTap = onTap
        self.onStatus = onStatus
        self.onMissedTapHint = onMissedTapHint
        self.onSample = onSample
    }

    func configure(enabled: Bool, sensitivity: Double, generation: UInt64) {
        lock.lock()
        wanted = enabled
        eligible = false
        self.sensitivity = sensitivity
        self.generation = generation
        let shouldLaunch = enabled && !running
        if shouldLaunch { running = true }
        lock.unlock()

        if shouldLaunch {
            let thread = Thread { [self] in self.run() }
            thread.name = "Relay ambient-light tap sensor"
            thread.qualityOfService = .utility
            thread.start()
        }
    }

    private var configuration: (enabled: Bool, sensitivity: Double, generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (wanted, sensitivity, generation)
    }

    func acceptsDelivery(at time: Double, generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return wanted
            && self.generation == generation
            && eligible
            && time >= eligibleSince
            && PhysicalTapClock.now - eligibilityCheckedAt <= 0.5
    }

    func drainForTermination() {
        lock.lock()
        wanted = false
        let deadline = Date().addingTimeInterval(1)
        while running {
            if !lock.wait(until: deadline) { break }
        }
        lock.unlock()
    }

    private func updateEligibility(at time: Double) {
        let allowed = lidGuard.allowsTap(at: time)
            && receivedAccel && receivedGyro && receivedLight
            && time - lastAccel < 0.1
            && time - lastGyro < 0.1
            && time - lastLight < 0.65
        if !allowed {
            detector.reset(at: time)
            missedTapDetector.reset()
        }
        lock.lock()
        if allowed && !eligible { eligibleSince = time }
        eligible = allowed
        eligibilityCheckedAt = time
        lock.unlock()
    }

    private func run() {
        var lastAttempt = -Double.infinity
        var publishedStatus: Status?
        var lastLidPoll = -Double.infinity
        var lastValidLidRead = 0.0
        while configuration.enabled {
            let config = configuration
            let now = PhysicalTapClock.now
            if streamGeneration != config.generation {
                streamGeneration = config.generation
                streamStarted = now
                lastAttempt = -.infinity
                detector.sensitivity = config.sensitivity
                detector.reset(at: now)
                missedTapDetector.reset()
                receivedLight = false
                receivedAccel = false
                receivedGyro = false
                lastAccel = now
                lastGyro = now
                lastLight = now
                publishedStatus = nil
                lastLidPoll = -.infinity
                lastValidLidRead = now
                lidGuard.reset(at: now)
            }
            if streams.isEmpty, now - lastAttempt >= 8 {
                lastAttempt = now
                onStatus(.starting, streamGeneration)
                if !open() {
                    close()
                    onStatus(.unavailable, streamGeneration)
                }
                streamStarted = now
                lastLight = now
                receivedLight = false
                receivedAccel = false
                receivedGyro = false
                lastAccel = now
                lastGyro = now
                detector.reset(at: now)
                missedTapDetector.reset()
                publishedStatus = nil
                lastLidPoll = -.infinity
                lastValidLidRead = now
                lidGuard.reset(at: now)
            }
            guard !streams.isEmpty else {
                Thread.sleep(forTimeInterval: 0.1)
                continue
            }
            let readingTime = PhysicalTapClock.now
            if readingTime - lastLidPoll >= 0.1 {
                lastLidPoll = readingTime
                let angle = readLidAngle()
                if angle != nil { lastValidLidRead = readingTime }
                onSample?(PhysicalTapSample(kind: .lid, time: readingTime, value: SIMD3(angle ?? .nan, 0, 0)))
                lidGuard.update(angle: angle, at: readingTime)
                updateEligibility(at: readingTime)
            }
            CFRunLoopRunInMode(.defaultMode, 0.05, false)
            let afterReports = PhysicalTapClock.now
            updateEligibility(at: afterReports)
            if afterReports - lastLight > 2 || afterReports - lastAccel > 2
                || afterReports - lastGyro > 2 || afterReports - lastValidLidRead > 2 {
                close()
                publishedStatus = nil
                onStatus(.stalled, streamGeneration)
            } else if receivedLight && receivedAccel && receivedGyro {
                let status: Status = lidGuard.allowsTap(at: PhysicalTapClock.now) ? .ready : .settling
                if status != publishedStatus {
                    publishedStatus = status
                    onStatus(status, streamGeneration)
                }
            }
        }
        close()
        lock.lock()
        running = false
        lock.broadcast()
        let restart = (wanted, sensitivity, generation)
        lock.unlock()
        if restart.0 {
            configure(enabled: true, sensitivity: restart.1, generation: restart.2)
        } else {
            onStatus(.stopped, restart.2)
        }
    }

    private func open() -> Bool {
        for service in Self.services("AppleSPUHIDDevice") {
            defer { IOObjectRelease(service) }
            let page = Self.number(service, "PrimaryUsagePage")
            let usage = Self.number(service, "PrimaryUsage")
            let isMotion = page == 0xFF00 && (usage == 3 || usage == 9) && Self.number(service, "MaxInputReportSize") == 22
            let isLight = page == 0xFF00 && usage == 4 && Self.number(service, "MaxInputReportSize") == 122
            let isLid = page == 0x20 && usage == 0x8A
            guard isMotion || isLight || isLid,
                  !streams.contains(where: { $0.usage == usage }),
                  !(isLid && lidDevice != nil),
                  let device = IOHIDDeviceCreate(kCFAllocatorDefault, service),
                  IOHIDDeviceOpen(device, 0) == kIOReturnSuccess else {
                continue
            }
            if isLid {
                lidDevice = device
                continue
            }
            let stream = StreamBox(device: device, usage: usage, owner: self)
            IOHIDDeviceRegisterInputReportWithTimeStampCallback(
                device,
                stream.buffer,
                128,
                physicalTapHIDReportCallback,
                Unmanaged.passUnretained(stream).toOpaque()
            )
            streams.append(stream)
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        }
        guard streams.count == 3, lidDevice != nil else { return false }
        // Best-effort ReportInterval tuning: unprivileged sessions may not be permitted to write
        // AppleSPUHIDDriver properties even though all 3 SPU streams + lid angle device opened cleanly.
        for driver in Self.services("AppleSPUHIDDriver") {
            let page = Self.number(driver, "PrimaryUsagePage")
            let usage = Self.number(driver, "PrimaryUsage")
            guard page == 0xFF00, usage == 3 || usage == 9,
                  let original = IORegistryEntryCreateCFProperty(driver, "ReportInterval" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  IORegistryEntrySetCFProperty(driver, "ReportInterval" as CFString, NSNumber(value: 1_250)) == kIOReturnSuccess else {
                IOObjectRelease(driver)
                continue
            }
            driverIntervals.append((driver, original))
        }
        return true
    }

    private func readLidAngle() -> Double? {
        guard let lidDevice else { return nil }
        var bytes = [UInt8](repeating: 0, count: 8)
        var count = bytes.count
        if IOHIDDeviceGetReport(lidDevice, kIOHIDReportTypeFeature, 7, &bytes, &count) == kIOReturnSuccess,
           count >= 5, bytes[0] == 7 {
            let raw = UInt32(bytes[1]) | (UInt32(bytes[2]) << 8) | (UInt32(bytes[3]) << 16) | (UInt32(bytes[4]) << 24)
            return Double(raw) / 100
        }
        count = bytes.count
        guard IOHIDDeviceGetReport(lidDevice, kIOHIDReportTypeFeature, 1, &bytes, &count) == kIOReturnSuccess,
              count >= 3, bytes[0] == 1 else {
            return nil
        }
        return Double(UInt16(bytes[1]) | (UInt16(bytes[2]) << 8))
    }

    private func close() {
        lock.lock()
        eligible = false
        lock.unlock()
        for stream in streams {
            IOHIDDeviceUnscheduleFromRunLoop(stream.device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceRegisterInputReportWithTimeStampCallback(stream.device, stream.buffer, 128, nil, nil)
            IOHIDDeviceClose(stream.device, 0)
        }
        streams.removeAll()
        if let lidDevice { IOHIDDeviceClose(lidDevice, 0) }
        lidDevice = nil
        for (driver, original) in driverIntervals {
            if Self.number(driver, "ReportInterval") == 1_250 {
                IORegistryEntrySetCFProperty(driver, "ReportInterval" as CFString, original)
            }
            IOObjectRelease(driver)
        }
        driverIntervals.removeAll()
        receivedAccel = false
        receivedGyro = false
        receivedLight = false
    }

    fileprivate func receiveMotion(usage: Int, value: SIMD3<Double>, at time: Double) {
        let now = PhysicalTapClock.now
        let config = configuration
        guard config.enabled, config.generation == streamGeneration,
              time >= streamStarted, abs(now - time) < 0.2 else { return }
        if usage == 3 {
            lastAccel = now
            receivedAccel = true
            onSample?(PhysicalTapSample(kind: .acceleration, time: time, value: value))
            detector.accel(value, at: time)
            missedTapDetector.accel(value, at: time)
        } else if usage == 9 {
            lastGyro = now
            receivedGyro = true
            onSample?(PhysicalTapSample(kind: .rotation, time: time, value: value))
            detector.gyro(value, at: time)
            let keyIdleSeconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
            let upIdleSeconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyUp)
            let modIdleSeconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .flagsChanged)
            let typingActive = PhysicalMissedTapDetector.keyboardActive(
                downAge: keyIdleSeconds,
                upAge: upIdleSeconds,
                modifierAge: modIdleSeconds
            )
            if lidGuard.allowsTap(at: time),
               missedTapDetector.rotation(value, at: time, inputActive: typingActive) {
                onMissedTapHint?(streamGeneration)
            }
        }
    }

    fileprivate func receiveLight(_ lux: Double, at time: Double) {
        let now = PhysicalTapClock.now
        let config = configuration
        guard config.enabled, config.generation == streamGeneration,
              time >= streamStarted, abs(now - time) < 0.2 else { return }
        receivedLight = true
        lastLight = now
        onSample?(PhysicalTapSample(kind: .light, time: time, value: SIMD3(lux, 0, 0)))
        guard lidGuard.allowsTap(at: time) else {
            detector.reset(at: time)
            return
        }
        if detector.light(lux, at: time) {
            missedTapDetector.clearSequence()
            onTap(time, streamGeneration)
        }
    }

    private static func number(_ service: io_service_t, _ key: String) -> Int {
        (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue ?? -1
    }

    private static func services(_ name: String) -> [io_service_t] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(name), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var result: [io_service_t] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            result.append(service)
        }
        return result
    }
}

// MARK: - App-Lifetime Physical Notch Tap Coordinator

@Observable @MainActor
final class PhysicalNotchTap {
    static let shared = PhysicalNotchTap()

    private(set) var status: PhysicalTapSensor.Status = .stopped
    private(set) var detectedTaps = 0
    private(set) var isEnabled = false
    private(set) var isCalibrating = false
    private(set) var showsMissedTapHint = false

    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var warmupOwners: Set<UUID> = []
    @ObservationIgnored private var configuredSensitivity: Double?
    @ObservationIgnored private var acceptingTaps = false
    @ObservationIgnored private var acceptingTapsSince = Double.infinity
    @ObservationIgnored private var sleeping = false
    @ObservationIgnored private var screenSleeping = false
    @ObservationIgnored private var locked = false
    @ObservationIgnored private var allowed: () -> Bool = { false }
    @ObservationIgnored private var onTap: () -> Void = {}
    @ObservationIgnored private var hintDismissTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    @ObservationIgnored private lazy var sensor: PhysicalTapSensor = PhysicalTapSensor(
        onTap: { [weak self] time, generation in
            Task { @MainActor in
                guard let self,
                      self.generation == generation,
                      self.isEnabled,
                      self.acceptingTaps,
                      time >= self.acceptingTapsSince,
                      PhysicalTapClock.now - time < 0.4,
                      self.sensor.acceptsDelivery(at: time, generation: generation),
                      self.allowed(),
                      !Self.screenLocked else { return }
                self.showsMissedTapHint = false
                self.detectedTaps += 1
                self.onTap()
            }
        },
        onStatus: { [weak self] status, generation in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                if self.isEnabled { self.status = status }
            }
        },
        onMissedTapHint: { [weak self] generation in
            Task { @MainActor in
                guard let self,
                      self.generation == generation,
                      self.isEnabled,
                      self.acceptingTaps,
                      self.allowed(),
                      !Self.screenLocked else { return }
                self.presentMissedTapHintBriefly()
            }
        }
    )

    var hasBuiltInNotchedDisplay: Bool {
        NSScreen.screens.contains { $0.relayIsBuiltIn && $0.relayHardwareNotchSize != nil }
    }

    var statusText: String {
        if isCalibrating { return "Calibration is in progress. Follow the calibration window." }
        if !NotchPreferences.physicalTapEnabled() { return "Physical taps are off." }
        if !NSScreen.screens.contains(where: \.relayIsBuiltIn) {
            return "External display active — physical notch taps require an open built-in MacBook display."
        }
        if sleeping || screenSleeping || locked { return "Paused while your Mac is asleep or locked." }
        switch status {
        case .ready: return "Ready. Tap the light-sensor area just left of the camera, then lift your finger."
        case .starting: return "Checking your Mac’s light, motion, and lid sensors…"
        case .settling: return "Touch detection resumes once the lid settles."
        case .unavailable: return "Physical taps aren’t available on this Mac or its sensors couldn’t be opened."
        case .stalled: return "A sensor stream paused. Relay will reconnect automatically."
        case .stopped: return "Available on supported MacBooks with the built-in display open."
        }
    }

    func start(allowed: @escaping () -> Bool, onTap: @escaping () -> Void) {
        self.allowed = allowed
        self.onTap = onTap
        guard !started else {
            refresh()
            return
        }
        started = true
        locked = Self.screenLocked
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { $0.sleeping = true; $0.refresh() }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.sleeping = false; $0.refresh() }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.screenSleeping = true; $0.refresh() }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.screenSleeping = false; $0.refresh() }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.locked = true; $0.refresh() }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.locked = Self.screenLocked; $0.refresh() }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")) { $0.locked = true; $0.refresh() }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked")) { $0.locked = false; $0.refresh() }
        observe(.default, NSApplication.didBecomeActiveNotification) { $0.refreshIfAdmissionChanged() }
        observe(.default, NSApplication.didResignActiveNotification) { $0.refreshIfAdmissionChanged() }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { $0.refresh() }
        observe(.default, .physicalNotchTapChanged) { $0.refresh() }
        observe(.default, NSApplication.willTerminateNotification) {
            $0.stop()
            $0.sensor.drainForTermination()
        }
        refresh()
    }

    func setWarmup(_ enabled: Bool, owner: UUID) {
        if enabled {
            guard warmupOwners.insert(owner).inserted else { return }
        } else {
            guard warmupOwners.remove(owner) != nil else { return }
        }
        refresh()
    }

    private var shouldRunSensor: Bool {
        let builtIn = NSScreen.screens.contains(where: \.relayIsBuiltIn)
        let warming = !warmupOwners.isEmpty && NSApp?.isActive == true
        return !isCalibrating
            && (allowed() || warming)
            && NotchPreferences.physicalTapEnabled()
            && builtIn
            && !sleeping && !screenSleeping && !locked && !Self.screenLocked
    }

    private func refreshIfAdmissionChanged() {
        let enabled = shouldRunSensor
        if isEnabled != enabled || acceptingTaps != (enabled && allowed()) {
            refresh()
        }
    }

    func refresh() {
        guard started else { return }
        let enabled = shouldRunSensor
        acceptingTaps = enabled && allowed()
        acceptingTapsSince = acceptingTaps ? PhysicalTapClock.now : .infinity
        let sensitivity = NotchPreferences.physicalTapThreshold()
        guard enabled != isEnabled || (enabled && configuredSensitivity != sensitivity) else { return }
        generation &+= 1
        isEnabled = enabled
        configuredSensitivity = sensitivity
        status = enabled ? .starting : .stopped
        sensor.configure(enabled: enabled, sensitivity: sensitivity, generation: generation)
    }

    func beginCalibration() {
        isCalibrating = true
        showsMissedTapHint = false
        refresh()
        sensor.drainForTermination()
    }

    func endCalibration() {
        isCalibrating = false
        refresh()
    }

    func stop() {
        generation &+= 1
        isEnabled = false
        status = .stopped
        started = false
        acceptingTaps = false
        acceptingTapsSince = .infinity
        showsMissedTapHint = false
        hintDismissTask?.cancel()
        hintDismissTask = nil
        warmupOwners.removeAll()
        configuredSensitivity = nil
        sensor.configure(enabled: false, sensitivity: 1.1, generation: generation)
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    private func presentMissedTapHintBriefly() {
        showsMissedTapHint = true
        hintDismissTask?.cancel()
        hintDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard let self, !Task.isCancelled else { return }
            self.showsMissedTapHint = false
        }
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        action: @escaping @MainActor (PhysicalNotchTap) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        observers.append((center, token))
    }

    private static var screenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}

// MARK: - Interactive Guided Calibration Window & Views

@Observable @MainActor
final class NotchTouchCalibration: NSObject, NSWindowDelegate {
    static let shared = NotchTouchCalibration()

    private(set) var isRunning = false
    private(set) var finished = false
    private(set) var passed = false
    private(set) var headline = "Fine-tune your touch"
    private(set) var instruction = "Touch already works with our default tuning. To personalize it, keep your Mac in its usual position for a quiet baseline, five taps, and two finger passes."
    private(set) var stepLabel = "About a minute"
    private(set) var countdown: Int?
    private(set) var isTapCue = false

    @ObservationIgnored private var guidePanel: NSPanel?
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var sensor: PhysicalTapSensor?
    @ObservationIgnored private var sensorStatus: PhysicalTapSensor.Status = .stopped
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var recording = false
    @ObservationIgnored private var runID = UUID()

    func show() {
        if window == nil {
            let panel = NSWindow(
                contentViewController: NSHostingController(
                    rootView: NotchTouchCalibrationView(calibration: self).preferredColorScheme(.dark)
                )
            )
            panel.title = "Calibrate notch touch"
            panel.identifier = NSUserInterfaceItemIdentifier("relay.notchTouchCalibration")
            panel.styleMask = [.titled, .closable]
            panel.isReleasedWhenClosed = false
            panel.backgroundColor = NSColor(white: 0.045, alpha: 1)
            panel.delegate = self
            panel.setContentSize(NSSize(width: 560, height: 540))
            if let screen = NSScreen.screens.first(where: \.relayIsBuiltIn) {
                panel.setFrameOrigin(NSPoint(
                    x: screen.visibleFrame.midX - panel.frame.width / 2,
                    y: screen.visibleFrame.midY - panel.frame.height / 2
                ))
            } else {
                panel.center()
            }
            window = panel
        }
        window?.makeKeyAndOrderFront(nil)
        showGuide()
        observeInterruptions()
        NSApp.activate(ignoringOtherApps: true)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        finished = false
        passed = false
        isTapCue = false
        showGuide()
        headline = "Let your lid settle"
        instruction = "Leave your Mac still while we connect to its sensors."
        stepLabel = "Getting ready"
        runID = UUID()
        let id = runID
        let defaults = UserDefaults.standard
        PhysicalNotchTap.shared.beginCalibration()
        observeInterruptions()
        let capture = PhysicalTapCalibrationCapture()
        sensorStatus = .starting
        let sensor = PhysicalTapSensor(
            onTap: { _, _ in },
            onStatus: { [weak self] status, _ in
                Task { @MainActor in
                    guard let self, self.runID == id, self.isRunning else { return }
                    self.sensorStatus = status
                }
            },
            onSample: { sample in capture.append(sample) }
        )
        self.sensor = sensor
        sensor.configure(enabled: true, sensitivity: 1.1, generation: 1)

        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let deadline = PhysicalTapClock.now + 12
                while self.sensorStatus != .ready {
                    try Task.checkCancellation()
                    if self.sensorStatus == .unavailable || PhysicalTapClock.now >= deadline {
                        throw CalibrationError(message: "We couldn’t get steady sensor readings. Keep the built-in display open and try again.")
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                self.recording = true
                var trials: [PhysicalTapCalibrationEvaluation.Trial] = []
                var start = PhysicalTapClock.now
                try await self.step(
                    "Hold still",
                    "Keep your hands off your Mac for the quiet baseline.",
                    label: "Quiet baseline",
                    seconds: 5
                )
                trials.append(.init(kind: .quiet, start: start, end: PhysicalTapClock.now))
                for index in 1...5 {
                    try await self.step(
                        "Get ready to tap",
                        "Touch the spot just left of the camera when “Tap once” appears.",
                        label: "Tap \(index) of 5",
                        seconds: 2
                    )
                    start = PhysicalTapClock.now
                    try await self.step(
                        "Tap once",
                        "Gently touch the marked spot on your real notch, then lift your finger.",
                        label: "Tap \(index) of 5",
                        seconds: 1,
                        tapCue: true
                    )
                    try await self.step(
                        "Hold still",
                        "Let the light and motion settle before the next tap.",
                        label: "Tap \(index) of 5",
                        seconds: 3
                    )
                    trials.append(.init(kind: .tap, start: start, end: PhysicalTapClock.now))
                }
                for index in 1...2 {
                    try await self.step(
                        "Get ready for a finger pass",
                        "Move a finger across the same spot, about 1 cm away, without touching the screen.",
                        label: "Finger pass \(index) of 2",
                        seconds: 3
                    )
                    start = PhysicalTapClock.now
                    try await self.step(
                        "Pass your finger",
                        "Move across the tap spot once without touching, then withdraw your hand.",
                        label: "Finger pass \(index) of 2",
                        seconds: 2
                    )
                    try await self.step(
                        "Hold still",
                        "Keep your hand away while the light settles.",
                        label: "Finger pass \(index) of 2",
                        seconds: 3
                    )
                    trials.append(.init(kind: .fingerPass, start: start, end: PhysicalTapClock.now))
                }
                self.recording = false
                self.headline = "Checking your touch"
                self.instruction = "Finding a sensitivity that separates your taps from the other movements."
                self.countdown = nil
                sensor.drainForTermination()
                guard let samples = capture.take() else {
                    throw CalibrationError(message: "The recording ran too long. Start a fresh calibration.")
                }
                let recordedTrials = trials
                let result = await Task.detached(priority: .userInitiated) {
                    PhysicalTapCalibrationEvaluation.evaluate(samples: samples, trials: recordedTrials)
                }.value
                try Task.checkCancellation()
                guard self.runID == id else { return }
                if let profile = result.profile, let sensitivity = profile.sensitivities.last {
                    defaults.set(try JSONEncoder().encode(profile), forKey: NotchPreferences.physicalTapCalibrationKey)
                    defaults.set(sensitivity, forKey: NotchPreferences.physicalTapSensitivityKey)
                    self.passed = true
                }
                self.finish(message: result.message)
            } catch is CancellationError {
                if self.runID == id { self.finish(message: "Calibration stopped. Start again when you’re ready.") }
            } catch {
                if self.runID == id {
                    self.finish(message: (error as? CalibrationError)?.message ?? "Calibration couldn’t finish. Please try again.")
                }
            }
        }
    }

    private func step(
        _ title: String,
        _ detail: String,
        label: String,
        seconds: Int,
        tapCue: Bool = false
    ) async throws {
        headline = title
        instruction = detail
        stepLabel = label
        isTapCue = tapCue
        let end = PhysicalTapClock.now + Double(seconds)
        while PhysicalTapClock.now < end {
            try Task.checkCancellation()
            if recording && sensorStatus != .ready {
                throw CalibrationError(message: "The lid moved or a sensor paused. Let your Mac settle, then try again.")
            }
            let remaining = max(1, Int(ceil(end - PhysicalTapClock.now)))
            if countdown != remaining { countdown = remaining }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func showGuide() {
        if let guidePanel {
            guidePanel.orderFrontRegardless()
            return
        }
        guard let screen = NSScreen.screens.first(where: \.relayIsBuiltIn),
              let notch = screen.relayHardwareNotchSize else { return }
        let lightSensorOffset = -notch.width * 54.0 / 370.0
        let panel = CalibrationGuidePanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.title = "Notch calibration tap guide"
        panel.setAccessibilityElement(false)
        panel.contentView = NSHostingView(rootView: NotchCalibrationGuide(calibration: self))
        let top = screen.frame.maxY - notch.height + 1
        panel.setFrame(
            NSRect(x: screen.relayCameraCenterX + lightSensorOffset - 42, y: top - 48, width: 84, height: 56),
            display: true
        )
        guidePanel = panel
        panel.orderFrontRegardless()
    }

    private final class CalibrationGuidePanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private func hideGuide() {
        guidePanel?.orderOut(nil)
        guidePanel?.close()
        guidePanel = nil
    }

    private func finish(message: String) {
        sensor?.drainForTermination()
        sensor = nil
        recording = false
        isRunning = false
        finished = true
        countdown = nil
        isTapCue = false
        if window?.isVisible != true { hideGuide() }
        headline = passed ? "Your touch is tuned" : "Let’s try that again"
        instruction = message
        stepLabel = passed ? "Personal tuning saved" : "Current tuning kept"
        if window?.isVisible != true { removeObservers() }
        PhysicalNotchTap.shared.endCalibration()
        NotificationCenter.default.post(name: .physicalNotchTapChanged, object: nil)
        task = nil
    }

    func cancel() {
        guard isRunning else { return }
        task?.cancel()
        runID = UUID()
        finish(message: "Calibration stopped. Start again when you’re ready.")
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        cancel()
        hideGuide()
        removeObservers()
        window = nil
    }

    func windowDidBecomeKey(_ notification: Notification) {
        showGuide()
    }

    private func observeInterruptions() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification
        ] {
            observe(workspace, name)
        }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked"))
        observe(.default, NSApplication.didChangeScreenParametersNotification)
        observe(.default, NSApplication.willTerminateNotification)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancel()
                self?.hideGuide()
            }
        }
        observers.append((center, token))
    }

    private func removeObservers() {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }

    private struct CalibrationError: Error {
        let message: String
    }
}

struct NotchTouchCalibrationView: View {
    let calibration: NotchTouchCalibration

    var body: some View {
        VStack(spacing: 20) {
            NotchCalibrationIllustration()
                .frame(height: 152)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Tap the glowing sensor region just left of the camera in your MacBook’s notch")

            Text(calibration.stepLabel)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(red: 0.72, green: 0.91, blue: 0.91))

            Text(calibration.headline)
                .font(.system(size: 28, weight: .semibold))
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("calibration.instruction")

            Text(calibration.instruction)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 440, minHeight: 56, alignment: .top)

            if let countdown = calibration.countdown {
                Text("\(countdown)")
                    .font(.system(size: 32, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .frame(height: 38)
            } else {
                Text(calibration.finished ? "" : "Successful calibration saves a personalized sensitivity.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(height: 38)
            }

            Spacer(minLength: 0)

            HStack {
                Button(calibration.isRunning ? "Cancel" : "Close") {
                    if calibration.isRunning { calibration.cancel() } else { calibration.close() }
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(RelaySecondaryButtonStyle())

                Spacer()

                if !calibration.isRunning {
                    Button(calibration.passed ? "Calibrate again" : calibration.finished ? "Try again" : "Start calibration") {
                        calibration.start()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(RelayPrimaryButtonStyle())
                    .accessibilityIdentifier("calibration.start")
                }
            }
            .textFieldStyle(.plain)
        }
        .padding(32)
        .frame(width: 560, height: 540)
        .background(Color(white: 0.045))
    }
}

private struct NotchCalibrationGuide: View {
    let calibration: NotchTouchCalibration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NotchTapLocationGuide(expanded: true, visible: true)
            .frame(width: 38, height: 26)
            .scaleEffect(1.4, anchor: .top)
            .opacity(calibration.isTapCue ? 1 : 0.85)
            .shadow(color: .black.opacity(0.7), radius: 2)
            .padding(.top, 8)
            .frame(width: 84, height: 56, alignment: .top)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: calibration.isTapCue)
            .allowsHitTesting(false)
            .preferredColorScheme(.dark)
    }
}

struct NotchCalibrationIllustration: View {
    private let sensorX: CGFloat = -320 * 54 / 370
    private let notch = NotchShape(topCornerRadius: 6, bottomCornerRadius: 11, isIsland: false)

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 18)
                .fill(LinearGradient(
                    colors: [Color(white: 0.12), Color(white: 0.065)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
            ZStack(alignment: .top) {
                notch.fill(.black)
                SensorOpalGlow()
                    .frame(width: 50, height: 50)
                    .offset(x: sensorX, y: 2)
                Circle()
                    .fill(Color(white: 0.045))
                    .overlay(Circle().strokeBorder(.white.opacity(0.28), lineWidth: 1))
                    .overlay(Circle().fill(.white.opacity(0.24)).frame(width: 3, height: 3))
                    .frame(width: 10, height: 10)
                    .offset(y: 22)
            }
            .frame(width: 320, height: 54)
            .clipShape(notch)

            NotchTapLocationGuide(expanded: true, visible: true)
                .frame(width: 38, height: 26)
                .offset(x: sensorX, y: 60)

            Text("Touch the glow, just left of the camera")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.64))
                .offset(y: 120)
        }
    }
}

private struct SensorOpalGlow: View {
    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(
                colors: [
                    Color(red: 0.36, green: 0.86, blue: 1.0).opacity(0.62),
                    Color(red: 1.0, green: 0.76, blue: 0.44).opacity(0.30),
                    .clear
                ],
                center: .center,
                startRadius: 2,
                endRadius: 24
            ))
            Circle()
                .fill(.white)
                .frame(width: 14, height: 14)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Passive Sensor Location Guide & Fingertip Shape

struct NotchTapLocationGuide: View {
    var expanded: Bool
    var visible: Bool

    private let opal = LinearGradient(stops: [
        .init(color: Color(red: 0.31, green: 0.86, blue: 1).opacity(0), location: 0),
        .init(color: Color(red: 0.40, green: 0.85, blue: 1), location: 0.15),
        .init(color: Color(red: 0.88, green: 1, blue: 0.95), location: 0.44),
        .init(color: Color(red: 1, green: 0.97, blue: 0.85), location: 0.60),
        .init(color: Color(red: 1, green: 0.77, blue: 0.54), location: 0.82),
        .init(color: Color(red: 1, green: 0.74, blue: 0.53).opacity(0), location: 1)
    ], startPoint: .leading, endPoint: .trailing)

    private let handLight = LinearGradient(colors: [
        Color(red: 0.76, green: 0.94, blue: 1),
        Color(red: 0.92, green: 1, blue: 0.91),
        Color(red: 1, green: 0.90, blue: 0.71)
    ], startPoint: .leading, endPoint: .trailing)

    var body: some View {
        ZStack(alignment: .top) {
            ZStack {
                Circle().fill(RadialGradient(colors: [
                    Color(red: 0.28, green: 0.79, blue: 1).opacity(0.36), .clear
                ], center: .center, startRadius: 0, endRadius: 17))
                .frame(width: 34, height: 34)
                .scaleEffect(x: expanded ? 0.85 : 1, y: expanded ? 0.74 : 0.50)
                .offset(x: expanded ? -5 : -8)

                Circle().fill(RadialGradient(colors: [
                    Color(red: 1, green: 0.72, blue: 0.40).opacity(0.38), .clear
                ], center: .center, startRadius: 0, endRadius: 17))
                .frame(width: 34, height: 34)
                .scaleEffect(x: expanded ? 0.85 : 1, y: expanded ? 0.74 : 0.50)
                .offset(x: expanded ? 5 : 8)
            }
            .frame(width: expanded ? 29 : 34, height: expanded ? 25 : 17)
            .offset(y: expanded ? 0 : -7)
            .opacity(expanded ? 0.65 : 1)

            TapLocationChevron(progress: expanded ? 1 : 0)
                .stroke(
                    expanded ? handLight : opal,
                    style: StrokeStyle(lineWidth: expanded ? 1.5 : 2, lineCap: .round, lineJoin: .round)
                )
                .frame(width: expanded ? 12 : 24, height: expanded ? 6 : 2)

            Capsule()
                .fill(LinearGradient(
                    colors: [.white.opacity(0), .white, .white.opacity(0)],
                    startPoint: .leading,
                    endPoint: .trailing
                ))
                .frame(width: 12, height: 0.75)
                .offset(y: 0.1)
                .scaleEffect(x: expanded ? 0.35 : 1, anchor: .center)
                .opacity(expanded ? 0 : 0.9)

            TapLocationFinger()
                .stroke(handLight, style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
                .frame(width: 14, height: 16)
                .offset(y: expanded ? 8 : 1)
                .scaleEffect(expanded ? 1 : 0.25, anchor: .top)
                .opacity(expanded ? 0.92 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(false)
    }
}

private nonisolated struct TapLocationChevron: Shape {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * progress))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * progress))
        return path
    }
}

nonisolated struct TapLocationFinger: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        path.move(to: point(0.34, 0.62))
        path.addLine(to: point(0.34, 0.15))
        path.addCurve(to: point(0.66, 0.15), control1: point(0.34, -0.05), control2: point(0.66, -0.05))
        path.addLine(to: point(0.66, 0.43))
        path.addCurve(to: point(0.94, 0.60), control1: point(0.85, 0.43), control2: point(0.94, 0.46))
        path.addLine(to: point(0.87, 0.88))
        path.addQuadCurve(to: point(0.73, 0.98), control: point(0.84, 0.98))
        path.addLine(to: point(0.43, 0.98))
        path.addQuadCurve(to: point(0.27, 0.88), control: point(0.34, 0.98))
        path.addLine(to: point(0.07, 0.62))
        path.addCurve(to: point(0.27, 0.53), control1: point(-0.04, 0.47), control2: point(0.12, 0.42))
        path.addLine(to: point(0.34, 0.62))
        return path
    }
}

// MARK: - Settings Section for Pane 2 (Notch & Shortcuts)

struct NotchTouchSettingsSection: View {
    @State private var enabled = NotchPreferences.physicalTapEnabled()
    @State private var secondAction = NotchPreferences.secondPhysicalTap()
    @State private var sensitivity = NotchPreferences.sensitivity()
    @State private var calibratedProfile = NotchPreferences.calibration()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                RelayIconBadge(icon: "hand.point.up.left.fill", color: RelayColors.accentAmethyst, size: 38, iconSize: 17)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Physical Notch Tap")
                        .font(.relayHeadline)
                        .foregroundStyle(RelayColors.textPrimary)
                    Text("Open Sidekick by physically tapping the MacBook camera notch bezel using the built-in accelerometer.")
                        .font(.relayCaption)
                        .foregroundStyle(RelayColors.textSecondary)
                }
                Spacer()
                Toggle(
                    "",
                    isOn: Binding(
                        get: { enabled },
                        set: { newValue in
                            enabled = newValue
                            NotchPreferences.setPhysicalTapEnabled(newValue)
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityIdentifier("notch.physicalTapToggle")
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text("Second physical tap")
                        .font(.relayCaptionStrong)
                        .foregroundStyle(RelayColors.textSecondary)
                        .frame(width: 130, alignment: .leading)
                    Picker(
                        "Second physical tap",
                        selection: Binding(
                            get: { secondAction },
                            set: { newValue in
                                secondAction = newValue
                                NotchPreferences.setSecondPhysicalTap(newValue)
                            }
                        )
                    ) {
                        ForEach(PhysicalTapAction.allCases, id: \.self) { action in
                            Text(action.label).tag(action)
                        }
                    }
                    .labelsHidden()
                    .disabled(!enabled)
                    .accessibilityIdentifier("notch.secondPhysicalTapPicker")
                    Spacer()
                }

                HStack(spacing: 12) {
                    Text("Touch sensitivity")
                        .font(.relayCaptionStrong)
                        .foregroundStyle(RelayColors.textSecondary)
                        .frame(width: 130, alignment: .leading)
                    Picker(
                        "Touch sensitivity",
                        selection: Binding(
                            get: { sensitivity },
                            set: { newValue in
                                sensitivity = newValue
                                NotchPreferences.setSensitivity(newValue)
                            }
                        )
                    ) {
                        ForEach(PhysicalTapSensitivity.allCases, id: \.self) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .disabled(!enabled)
                    .accessibilityIdentifier("notch.physicalTapSensitivity")
                }

                Divider().overlay(RelayTheme.line)

                HStack {
                    Text(PhysicalNotchTap.shared.statusText)
                        .font(.relayCaption)
                        .foregroundStyle(RelayColors.textSecondary)
                    Spacer()
                    Button(calibratedProfile == nil ? "Calibrate Touch…" : "Recalibrate Touch…") {
                        NotchTouchCalibration.shared.show()
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .disabled(!PhysicalNotchTap.shared.hasBuiltInNotchedDisplay)
                    .accessibilityIdentifier("notch.calibrateTouch")
                }
            }
            .padding(14)
            .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
            )
        }
        .padding(20)
        .relayGlassCard(cornerRadius: RelayTheme.radius)
        .onReceive(NotificationCenter.default.publisher(for: .physicalNotchTapChanged)) { _ in
            enabled = NotchPreferences.physicalTapEnabled()
            secondAction = NotchPreferences.secondPhysicalTap()
            sensitivity = NotchPreferences.sensitivity()
            calibratedProfile = NotchPreferences.calibration()
        }
    }
}

fileprivate extension NSScreen {
    var relayDisplayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    var relayIsBuiltIn: Bool {
        let id = relayDisplayID
        return id != 0 && CGDisplayIsBuiltin(id) != 0
    }

    var relayHardwareNotchSize: CGSize? {
        guard safeAreaInsets.top > 0 else { return nil }
        let left = auxiliaryTopLeftArea ?? .zero
        let right = auxiliaryTopRightArea ?? .zero
        let width: CGFloat
        if !left.isEmpty, !right.isEmpty, left.maxX < right.minX {
            width = right.minX - left.maxX
        } else {
            width = 200
        }
        return CGSize(width: width, height: safeAreaInsets.top)
    }

    var relayCameraCenterX: CGFloat {
        let left = auxiliaryTopLeftArea ?? .zero
        let right = auxiliaryTopRightArea ?? .zero
        if !left.isEmpty, !right.isEmpty, left.maxX < right.minX {
            return (left.maxX + right.minX) / 2
        }
        return frame.midX
    }
}
