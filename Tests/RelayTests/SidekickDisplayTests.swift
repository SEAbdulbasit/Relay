import Foundation
import Testing
@testable import Relay

struct SidekickDisplayTests {
    private let laptop = SidekickDisplayDescriptor(id: 1, name: "Laptop", layout: .init(
        screen: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleTop: 945, notchInset: 37, notchWidth: 220))
    private let left = SidekickDisplayDescriptor(id: 2, name: "Left display", layout: .init(
        screen: CGRect(x: -1920, y: 100, width: 1920, height: 1080), visibleTop: 1156, notchInset: 0, notchWidth: 0))
    private let upper = SidekickDisplayDescriptor(id: 3, name: "Upper display", layout: .init(
        screen: CGRect(x: 0, y: 982, width: 2560, height: 1440), visibleTop: 2398, notchInset: 0, notchWidth: 0))

    @Test func openingOnAnotherDisplayLeavesOneEntryOnEveryOtherDisplay() throws {
        let screens = [laptop, left, upper]
        let selected = try #require(SidekickDisplayDescriptor.mainDisplay(in: screens, preferredID: left.id))
        #expect(selected.id == left.id)
        let entries = SidekickDisplayDescriptor.entryDisplays(in: screens, mainDisplayID: selected.id, pinned: true)
        #expect(Set(entries.map(\.id)) == [laptop.id, upper.id])
        #expect(!entries.contains(where: { $0.id == selected.id }))
        #expect(selected.layout.canvas.maxX <= selected.layout.screen.maxX)
        #expect(selected.layout.canvas.minX >= selected.layout.screen.minX)
        #expect(selected.layout.canvas.maxY < selected.layout.visibleTop)
    }

    @Test func unpluggingTheActiveDisplayReturnsToTheNotchAndRemovesItsHandle() throws {
        let remaining = [laptop, upper]
        let selected = try #require(SidekickDisplayDescriptor.mainDisplay(in: remaining, preferredID: left.id))
        #expect(selected.id == laptop.id)
        let entries = SidekickDisplayDescriptor.entryDisplays(in: remaining, mainDisplayID: selected.id, pinned: true)
        #expect(entries.map(\.id) == [upper.id])
        #expect(entries[0].entryFrame.maxY == upper.layout.visibleTop - 4)
        #expect(laptop.entryFrame.maxY == laptop.layout.screen.maxY)
    }

    @Test func unpinningAndMirroredInventoryCannotLeaveExtraEntryWindows() {
        #expect(SidekickDisplayDescriptor.entryDisplays(in: [laptop, left], mainDisplayID: 1, pinned: false).isEmpty)
        let entries = SidekickDisplayDescriptor.entryDisplays(in: [laptop, left, left], mainDisplayID: 1, pinned: true)
        #expect(entries.map(\.id) == [2])
        #expect(SidekickDisplayDescriptor.mainDisplay(in: []) == nil)
    }
}
