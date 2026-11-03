import Testing
@testable import KallilexKit

/// Unit tests for `InfoPlist.resolve(_:)`, the pure validation behind
/// `InfoPlist.value(for:)`. Doesn't touch `Bundle.main` — see
/// `issues-ios/spec-ios-04-models-and-stores.md`, decision 4.
struct InfoPlistTests {
    @Test func nilIsUnresolved() {
        #expect(InfoPlist.resolve(nil) == nil)
    }

    @Test func emptyStringIsUnresolved() {
        #expect(InfoPlist.resolve("") == nil)
    }

    @Test func unresolvedBuildSettingPlaceholderIsUnresolved() {
        #expect(InfoPlist.resolve("$(KALLILEX_APP_GROUP)") == nil)
    }

    @Test func nonStringValueIsUnresolved() {
        #expect(InfoPlist.resolve(42) == nil)
    }

    @Test func validStringResolves() {
        #expect(InfoPlist.resolve("group.com.webcommits.kallilex") == "group.com.webcommits.kallilex")
    }
}
