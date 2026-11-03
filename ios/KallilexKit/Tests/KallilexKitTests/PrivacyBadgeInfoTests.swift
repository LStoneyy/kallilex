import Foundation
import Testing
import KallilexKit

/// Tests for `PrivacyBadgeInfo`'s text and symbol selection. See
/// `issues-ios/spec-ios-06-container-app-settings.md`.
struct PrivacyBadgeInfoTests {
    @Test func onDeviceShowsOnDevice() {
        let profile = ProviderProfile(id: "a", name: "Apple", kind: .appleOnDevice, baseUrl: "", model: "")
        let info = PrivacyBadgeInfo(profile: profile)
        #expect(info.classification == .onDevice)
        #expect(info.title == "On device")
    }

    @Test func localShowsThisDevice() {
        let profile = ProviderProfile(id: "a", name: "Mine", baseUrl: "http://localhost:11434/v1", model: "m")
        let info = PrivacyBadgeInfo(profile: profile)
        #expect(info.classification == .local)
        #expect(info.title == "This device")
    }

    @Test func lanShowsYourNetwork() {
        let profile = ProviderProfile(id: "a", name: "Mine", baseUrl: "http://your-mac.local:11434/v1", model: "m")
        let info = PrivacyBadgeInfo(profile: profile)
        #expect(info.classification == .lan)
        #expect(info.title == "Your network")
    }

    @Test func cloudShowsCloudAndTheHost() {
        let profile = ProviderProfile(id: "a", name: "Mine", baseUrl: "https://api.openai.com/v1", model: "m")
        let info = PrivacyBadgeInfo(profile: profile)
        #expect(info.classification == .cloud)
        #expect(info.title == "Cloud: api.openai.com")
    }

    @Test func unknownKindShowsUnsupported() {
        let profile = ProviderProfile(
            id: "a", name: "Mystery", kind: .unknown("applePrivateCloud"),
            baseUrl: "https://example.com/v1", model: "m"
        )
        let info = PrivacyBadgeInfo(profile: profile)
        #expect(info.classification == nil)
        #expect(info.title == "Unsupported")
    }

    @Test func accessibilityLabelMatchesTheTitle() {
        let profile = ProviderProfile(id: "a", name: "Mine", baseUrl: "https://api.openai.com/v1", model: "m")
        let info = PrivacyBadgeInfo(profile: profile)
        #expect(info.accessibilityLabel == info.title)
    }

    @Test func anUnparseableBaseUrlFallsBackToTheRawString() {
        let profile = ProviderProfile(id: "a", name: "Mine", baseUrl: "not a url", model: "m")
        let info = PrivacyBadgeInfo(profile: profile)
        #expect(info.classification == nil)
        #expect(info.title == "Unsupported")
    }
}
