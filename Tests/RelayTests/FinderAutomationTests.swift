import Foundation
import Testing
@testable import Relay

@MainActor
struct FinderAutomationTests {
    @Test func onlyRecognizedVisibleEnabledToolbarSearchFieldsQualify() {
        func allows(_ role: String, subrole: String = "", description: String = "", toolbar: Bool = true,
                    enabled: Bool = true, hidden: Bool = false) -> Bool {
            FinderAutomation.isSearchControl(role: role, subrole: subrole, roleDescription: description,
                                             inToolbar: toolbar, enabled: enabled, hidden: hidden)
        }
        #expect(allows("AXSearchField"))
        #expect(allows("AXTextField", subrole: "AXSearchField"))
        #expect(allows("AXTextField", description: "Search text field"))
        #expect(!allows("AXTextField", description: "text field"))
        #expect(!allows("AXTextField", description: "Search name to rename"))
        #expect(!allows("AXTextField", subrole: "AXSecureTextField", description: "search field"))
        #expect(!allows("AXSearchField", toolbar: false))
        #expect(!allows("AXSearchField", enabled: false))
        #expect(!allows("AXSearchField", hidden: true))
    }

    @Test func replacementRequiresExactWholeUTF16QuerySelection() {
        let value = "ملف👩‍💻"
        #expect(FinderAutomation.wholeQuerySelected(value: value, range: CFRange(location: 0, length: value.utf16.count)))
        #expect(!FinderAutomation.wholeQuerySelected(value: value, range: CFRange(location: 0, length: value.count)))
        #expect(!FinderAutomation.wholeQuerySelected(value: value, range: CFRange(location: 1, length: value.utf16.count)))
        #expect(!FinderAutomation.wholeQuerySelected(value: value, range: nil))
        #expect(FinderAutomation.wholeQuerySelected(value: "", range: CFRange(location: 0, length: 0)))
    }

    @Test func unicodeQueryCannotCarryReturnOrDelete() throws {
        #expect(try FinderAutomation.validatedQuery("ملف👩‍💻.txt") == "ملف👩‍💻.txt")
        for query in ["first\rsecond", "first\nsecond", "first\u{7f}second", "first\u{2028}second"] {
            #expect(throws: RelayError.self) { try FinderAutomation.validatedQuery(query) }
        }
        #expect(FinderAutomation.isSearchResultsView(title: "Searching “This Mac”"))
        #expect(!FinderAutomation.isSearchResultsView(title: "This Mac"))
    }

    @Test func finderIconAndListViewsQualifyWithoutReadingArbitraryLists() {
        #expect(FinderAutomation.isResultContainer(role: "AXList", identifier: "IconView"))
        #expect(FinderAutomation.isResultContainer(role: "AXList", identifier: "ListView"))
        #expect(FinderAutomation.isResultContainer(role: "AXCollection", identifier: "IconView"))
        #expect(!FinderAutomation.isResultContainer(role: "AXList", identifier: "sidebar"))
        #expect(!FinderAutomation.isResultContainer(role: "AXList", identifier: ""))
        #expect(!FinderAutomation.isResultContainer(role: "AXOutline", identifier: "IconView"))
        #expect(!FinderAutomation.isResultContainer(role: "AXToolbar", identifier: "ListView"))
    }

    @Test func exactVisibleFilenameEvidenceDoesNotConfuseQueryOrSubstringWithAResult() {
        func matches(_ labels: [String], role: String = "AXImage", results: Bool = true, hidden: Bool = false) -> Bool {
            FinderAutomation.isExactVisibleFilename(query: "sf.webm", role: role, labels: labels,
                insideResults: results, hidden: hidden)
        }
        #expect(matches(["sf.webm"]))
        #expect(matches(["", "sf.webm"], role: "AXStaticText"))
        #expect(!matches(["my-sf.webm", "sf.webm.backup", "SF.WEBM"]))
        #expect(!matches(["sf.webm"], results: false))
        #expect(!matches(["sf.webm"], hidden: true))
        #expect(!matches(["sf.webm"], role: "AXTextField"))
        #expect(!matches(["sf.webm"], role: "AXButton"))
        #expect(!matches([]))
    }
}
