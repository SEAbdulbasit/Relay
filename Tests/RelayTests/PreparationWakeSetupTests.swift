import Foundation
import IOKit.pwr_mgt
import Testing
@testable import Relay

struct PreparationWakeSetupTests {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    @Test func nextWakeRequiresExternalPowerAndUsesExactLocalTime() throws {
        let now = date("2026-11-06T01:00:00Z")
        let zone = try #require(TimeZone(identifier: "Asia/Riyadh"))
        func plan(enabled: Bool, external: Bool, limited: Bool) -> PreparationWakeSetup {
            PreparationWakeSetup.make(now: now, timeZone: zone, hour: 5, minute: 35, lastHandledDay: nil,
                                      enabled: enabled, onExternalPower: external, powerLimited: limited, scheduledDates: [])
        }
        #expect(plan(enabled: false, external: true, limited: false).request == nil)
        #expect(plan(enabled: true, external: false, limited: false).request == nil)
        #expect(plan(enabled: true, external: true, limited: true).request == nil)
        let request = try #require(plan(enabled: true, external: true, limited: false).request)
        #expect(request.date == date("2026-11-06T02:35:00Z"))
        #expect(request.command == "sudo /usr/bin/pmset schedule wake '11/06/26 05:35:00' '\(PreparationWakeSystem.owner)'")
    }

    @Test func aHandledDayAndImminentWakeUseTomorrowInstead() throws {
        let earlier = date("2026-11-06T08:00:00Z")
        let imminent = date("2026-11-06T08:57:00Z")
        for (now, handledDay) in [(imminent, nil), (earlier, "2026-11-06")] as [(Date, String?)] {
            let plan = PreparationWakeSetup.make(now: now, timeZone: utc, hour: 9, minute: 0, lastHandledDay: handledDay,
                                                enabled: true, onExternalPower: true, powerLimited: false, scheduledDates: [])
            #expect(plan.request?.date == date("2026-11-07T09:00:00Z"))
        }
        let rolledBack = PreparationWakeSetup.make(now: earlier, timeZone: utc, hour: 9, minute: 0, lastHandledDay: "2026-11-07",
                                                   enabled: true, onExternalPower: true, powerLimited: false, scheduledDates: [])
        #expect(rolledBack.request == nil)
    }

    @Test func queueReadbackSuppressesDuplicatesAndExposesExactCancellationWhileOff() throws {
        let pending = date("2026-11-06T09:30:00Z")
        let now = date("2026-11-06T08:00:00Z")
        let unrelated = date("2026-11-06T10:00:00Z")
        let past = date("2026-11-05T10:00:00Z")
        func row(_ owner: String, _ type: String, _ at: Date) -> [String: Any] {
            [kIOPMPowerEventAppNameKey: owner, kIOPMPowerEventTypeKey: type, kIOPMPowerEventTimeKey: at]
        }
        let queue = PreparationWakeSystem.relayWakeDates(in: [
            row("another.owner", kIOPMAutoWake, unrelated),
            row(PreparationWakeSystem.owner, kIOPMAutoSleep, unrelated),
            row(PreparationWakeSystem.owner, kIOPMAutoWake, pending),
            row(PreparationWakeSystem.owner, kIOPMAutoWake, pending),
            row(PreparationWakeSystem.owner, kIOPMAutoWake, past)
        ])
        let setup = PreparationWakeSetup.make(now: now, timeZone: utc, hour: 11, minute: 0, lastHandledDay: nil,
                                             enabled: false, onExternalPower: false, powerLimited: true, scheduledDates: queue)
        #expect(setup.request == nil)
        #expect(setup.pending == [pending])
        #expect(setup.cancellations.map(\.command) == [
            "sudo /usr/bin/pmset schedule cancel wake '11/06/26 09:30:00' '\(PreparationWakeSystem.owner)'"
        ])
    }

    @Test func unreadableOwnQueueEntryCannotOfferAnotherWake() {
        let queue = PreparationWakeSystem.relayWakeDates(in: [
            [kIOPMPowerEventAppNameKey: PreparationWakeSystem.owner, kIOPMPowerEventTypeKey: kIOPMAutoWake, kIOPMPowerEventTimeKey: "invalid"]
        ])
        #expect(queue == nil)
        let setup = PreparationWakeSetup.make(now: date("2026-11-06T08:00:00Z"), timeZone: utc, hour: 9, minute: 0,
                                             lastHandledDay: nil, enabled: true, onExternalPower: true,
                                             powerLimited: false, scheduledDates: queue)
        #expect(setup.request == nil)
        #expect(setup.status.contains("couldn’t check"))
    }

    @Test func springTimeGapResolvesAndFallRepetitionCannotBeArmedOrCancelledAmbiguously() throws {
        let zone = try #require(TimeZone(identifier: "America/New_York"))
        let spring = PreparationWakeSetup.make(now: date("2026-03-08T06:00:00Z"), timeZone: zone, hour: 2, minute: 30,
                                              lastHandledDay: nil, enabled: true, onExternalPower: true,
                                              powerLimited: false, scheduledDates: [])
        #expect(spring.request?.date == date("2026-03-08T07:00:00Z"))
        let fallNow = date("2026-11-01T04:00:00Z")
        let fall = PreparationWakeSetup.make(now: fallNow, timeZone: zone, hour: 1, minute: 30,
                                            lastHandledDay: nil, enabled: true, onExternalPower: true,
                                            powerLimited: false, scheduledDates: [])
        #expect(fall.request == nil)
        let repeated = [date("2026-11-01T05:30:00Z"), date("2026-11-01T06:30:00Z")]
        let cancellation = PreparationWakeSetup.make(now: fallNow, timeZone: zone, hour: 1, minute: 30,
                                                    lastHandledDay: nil, enabled: true, onExternalPower: true,
                                                    powerLimited: false, scheduledDates: repeated)
        #expect(cancellation.pending == repeated)
        #expect(cancellation.cancellations.isEmpty)
    }
}
