import Foundation

let paritySuiteProcessStart = ContinuousClock.now

func awaitParitySuiteQuietWindow(milliseconds: Int = 12000) async {
    let target = paritySuiteProcessStart.advanced(by: .milliseconds(milliseconds))
    if ContinuousClock.now < target {
        try? await Task.sleep(until: target, clock: .continuous)
    }
}

func awaitMCPQuietWindow() async {
    let target = paritySuiteProcessStart.advanced(by: .milliseconds(5000))
    if ContinuousClock.now < target {
        try? await Task.sleep(until: target, clock: .continuous)
    }
    let now = paritySuiteProcessStart.duration(to: .now)
    if now >= .milliseconds(24000) && now < .milliseconds(33500) {
        let bridge = paritySuiteProcessStart.advanced(by: .milliseconds(33500))
        try? await Task.sleep(until: bridge, clock: .continuous)
    }
}
