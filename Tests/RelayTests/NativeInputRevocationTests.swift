import Foundation
import Testing
@testable import Relay

struct NativeInputRevocationTests {
    @Test func revocationBeforeAdmissionRefusesEveryOutstandingAndFutureTicket() {
        let source = NativeInputRevocation(), old = source.ticket(), now = ContinuousClock.now
        source.revoke()
        #expect(old.admit(now: now, notAfter: now.advanced(by: .seconds(1))) == .revoked)
        #expect(source.ticket().admit(now: now, notAfter: now.advanced(by: .seconds(1))) == .revoked)
    }
    @Test func admissionIsOneUseAndRevocationDoesNotClaimToRetractInFlightInput() {
        let source = NativeInputRevocation(), ticket = source.ticket(), now = ContinuousClock.now
        #expect(ticket.admit(now: now, notAfter: now.advanced(by: .seconds(1))) == .admitted)
        #expect(ticket.admit(now: now, notAfter: now.advanced(by: .seconds(1))) == .consumed)
        source.revoke()
        #expect(source.ticket().admit(now: now, notAfter: now.advanced(by: .seconds(1))) == .revoked)
    }
    @Test func expiryRefusesBeforeAdmittingAndWithoutRealSleeping() {
        let source = NativeInputRevocation(), ticket = source.ticket(), now = ContinuousClock.now
        #expect(ticket.admit(now: now.advanced(by: .seconds(3)), notAfter: now.advanced(by: .seconds(2))) == .expired)
    }
}
