import Foundation
import Testing
@testable import Relay

struct ManagedPreparationAwakeLeaseTests {
    private final class Fixture {
        var marker = ManagedPreparationAwakeLease.RecoveryMarker.absent
        var sleepDisabled = false
        var onPower = true
        var failsRestore = false
        var writes: [Bool] = []

        func lease() -> ManagedPreparationAwakeLease {
            ManagedPreparationAwakeLease(system: .init(
                marker: { self.marker },
                createMarker: { self.marker = .owned; return true },
                removeMarker: { self.marker = .absent; return true },
                sleepDisabled: { self.sleepDisabled },
                setSleepDisabled: { value in
                    self.writes.append(value)
                    if !value, self.failsRestore { return false }
                    self.sleepDisabled = value
                    return true
                },
                onExternalPower: { self.onPower }
            ))
        }
    }

    @Test func lossOfHeartbeatRestoresSleepAndIgnoresUnrelatedRelease() {
        let fixture = Fixture()
        var lease = fixture.lease()
        let owner = NSObject()
        let other = NSObject()
        let token = UUID()
        let started = lease.begin(owner: ObjectIdentifier(owner), token: token, now: 0)
        let endedByOther = lease.end(owner: ObjectIdentifier(other))
        let heartbeatAccepted = lease.heartbeat(owner: ObjectIdentifier(owner), token: token, now: 40)
        let beforeDeadline = lease.check(now: 84)
        let atDeadline = lease.check(now: 85)
        #expect(started && !endedByOther && heartbeatAccepted && beforeDeadline && !atDeadline)
        #expect(!fixture.sleepDisabled)
        #expect(fixture.marker == .absent)
        #expect(fixture.writes == [true, false])
    }

    @Test func continuousHeartbeatCannotExtendTheAbsoluteLimit() {
        let fixture = Fixture()
        var lease = fixture.lease()
        let owner = NSObject()
        let token = UUID()
        let started = lease.begin(owner: ObjectIdentifier(owner), token: token, now: 0)
        #expect(started)
        for time in stride(from: 10, to: 1_200, by: 10) {
            let heartbeatAccepted = lease.heartbeat(owner: ObjectIdentifier(owner), token: token, now: Double(time))
            #expect(heartbeatAccepted)
        }
        let heartbeatAtLimit = lease.heartbeat(owner: ObjectIdentifier(owner), token: token, now: 1_200)
        #expect(!heartbeatAtLimit)
        #expect(fixture.writes == [true, false])
    }

    @Test func powerLossAndFailedRestoreLeaveRecoveryForTheNextHelper() {
        let fixture = Fixture()
        var lease = fixture.lease()
        let owner = NSObject()
        let started = lease.begin(owner: ObjectIdentifier(owner), token: UUID(), now: 0)
        #expect(started)
        fixture.failsRestore = true
        fixture.onPower = false
        let activeAfterPowerLoss = lease.check(now: 5)
        #expect(!activeAfterPowerLoss)
        #expect(fixture.sleepDisabled && fixture.marker == .owned)

        fixture.failsRestore = false
        var restarted = fixture.lease()
        let activeAfterRestart = restarted.check(now: 6)
        #expect(!activeAfterRestart)
        #expect(!fixture.sleepDisabled && fixture.marker == .absent)
    }

    @Test func leavesPreexistingDisabledSleepAndInvalidRecoveryFileAlone() {
        let fixture = Fixture()
        var lease = fixture.lease()
        let owner = NSObject()
        fixture.sleepDisabled = true
        let started = lease.begin(owner: ObjectIdentifier(owner), token: UUID(), now: 0)
        let activeWithExistingOverride = lease.check(now: 1)
        fixture.marker = .invalid
        let activeWithInvalidMarker = lease.check(now: 2)
        #expect(!started && !activeWithExistingOverride && !activeWithInvalidMarker)
        #expect(fixture.sleepDisabled && fixture.writes.isEmpty)
    }

    @Test func readsOnlyAnUnambiguousSystemWideSleepValue() {
        #expect(ManagedPreparationSleepSystem.parseSleepDisabled("System-wide power settings:\n SleepDisabled\t\t0\n") == false)
        #expect(ManagedPreparationSleepSystem.parseSleepDisabled("SleepDisabled 1") == true)
        #expect(ManagedPreparationSleepSystem.parseSleepDisabled("SleepDisabled 0\nSleepDisabled 1") == nil)
        #expect(ManagedPreparationSleepSystem.parseSleepDisabled("sleep 0") == nil)
    }
}
