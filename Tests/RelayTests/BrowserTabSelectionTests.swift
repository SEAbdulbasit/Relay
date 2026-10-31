import Foundation
import Testing
@testable import Relay

@MainActor
struct BrowserTabSelectionTests {
    private func tab(_ index: Int, value: Bool? = nil, selected: Bool? = nil, role: String = "AXRadioButton") -> BrowserAutomation.TabSelectionState {
        .init(index: index, role: role, value: value, selected: selected)
    }

    @Test func chromeDirectRadioValueFallbackFindsExactlyOneOfManyTabs() {
        let tabs = (0..<43).map { tab($0, value: $0 == 31) }
        #expect(BrowserAutomation.selectedTabIndex(explicit: nil, tabs: tabs, traversalComplete: true) == 31)
        #expect(BrowserAutomation.selectedTabIndex(explicit: [], tabs: tabs, traversalComplete: true) == 31)
        #expect(BrowserAutomation.selectedTabIndex(explicit: [31], tabs: tabs, traversalComplete: true) == 31)
        #expect(BrowserAutomation.selectedTabIndex(explicit: [4], tabs: tabs, traversalComplete: true) == nil)
    }

    @Test func selectedBooleanFallbackSupportsDirectAXTabs() {
        let tabs = [tab(1, selected: false, role: "AXTab"), tab(2, selected: true, role: "AXTab")]
        #expect(BrowserAutomation.selectedTabIndex(explicit: nil, tabs: tabs, traversalComplete: true) == 2)
        #expect(BrowserAutomation.selectedTabIndex(explicit: [2], tabs: tabs, traversalComplete: true) == 2)
    }

    @Test func ambiguousUnknownConflictingOrIncompleteStatesNeverQualify() {
        for tabs in [
            [tab(0, value: true), tab(1, value: true)],
            [tab(0, value: false), tab(1, value: false)],
            [tab(0, value: true, selected: false), tab(1, value: false)],
            [tab(0, value: true), tab(1)],
            [tab(0, value: true, role: "AXButton")],
            [tab(0, value: true), tab(0, value: false)]
        ] {
            #expect(BrowserAutomation.selectedTabIndex(explicit: nil, tabs: tabs, traversalComplete: true) == nil)
        }
        #expect(BrowserAutomation.selectedTabIndex(explicit: nil, tabs: [tab(0, value: true)], traversalComplete: false) == nil)
        #expect(BrowserAutomation.selectedTabIndex(explicit: nil, tabs: [], traversalComplete: true) == nil)
    }

    @Test func explicitSelectionMustBeDirectUniqueAndConsistentWithBooleanEvidence() {
        let tabs = [tab(0, value: false), tab(1, value: true)]
        for explicit in [[0], [0, 1], [1, 1], [7]] {
            #expect(BrowserAutomation.selectedTabIndex(explicit: explicit, tabs: tabs, traversalComplete: true) == nil)
        }
        #expect(BrowserAutomation.selectedTabIndex(explicit: [1], tabs: [tab(0), tab(1)], traversalComplete: true) == 1)
        #expect(BrowserAutomation.selectedTabIndex(explicit: [1], tabs: [tab(0, value: true), tab(1)], traversalComplete: true) == nil)
    }
    @Test func safariStartPageContentGroupDoesNotInventASelectedTab() {
        #expect(BrowserAutomation.isNonTabContentGroup(childRoles: ["AXScrollArea", "AXCollection"], complete: true))
        #expect(BrowserAutomation.isNonTabContentGroup(childRoles: [], complete: true))
        for roles in [["AXTab"], ["AXRadioButton", "AXGroup"], [""], Array(repeating: "AXGroup", count: 201)] {
            #expect(!BrowserAutomation.isNonTabContentGroup(childRoles: roles, complete: true))
        }
        #expect(!BrowserAutomation.isNonTabContentGroup(childRoles: ["AXCollection"], complete: false))
        #expect(BrowserAutomation.selectedTabIndex(explicit: nil, tabs: [], traversalComplete: true) == nil)
    }

}
