import Foundation
import Testing
@testable import InkstoneCore

struct WebDAVSettingsTests {
    @Test func missingSchemeDefaultsToHTTPSAndHTTPRequiresExplicitChoice() throws {
        var settings = WebDAVSettings()
        settings.url = " example.com:8443/notes "
        #expect(try settings.endpoint().absoluteString == "https://example.com:8443/notes/")
        settings.url = "http://example.com/notes"
        #expect(throws: SyncFailure.self) { try settings.endpoint() }
        #expect(throws: SyncFailure.self) { try WebDAV(settings: settings, password: "test") }
        settings.allowInsecureHTTP = true
        #expect(try settings.endpoint().absoluteString == "http://example.com/notes/")
        settings.url = "example.com/notes"
        #expect(try settings.endpoint().scheme == "https")
    }
    @Test func legacyHTTPKeepsCredentialIdentityWithoutAuthorizingNetwork() throws {
        let legacy = Data(#"{"url":"http://example.com/notes","username":"alice"}"#.utf8)
        var settings = try JSONDecoder().decode(WebDAVSettings.self, from: legacy)
        #expect(!settings.allowInsecureHTTP)
        let oldIdentity = "http://example.com/notes/\nalice"
        #expect(try settings.credentialIdentity() == oldIdentity)
        #expect(throws: SyncFailure.self) { try settings.endpoint() }
        settings.allowInsecureHTTP = true
        #expect(try settings.credentialIdentity() == oldIdentity)
        #expect(try JSONDecoder().decode(WebDAVSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }
    @Test func invalidAddressesNeverBecomeTransportEndpoints() {
        for input in ["", "  ", "ftp://example.com/notes", "https://user:pass@example.com/", "https://example.com/?secret=1", "https://example.com/#notes", "/relative/path"] {
            var settings = WebDAVSettings(); settings.url = input
            #expect(throws: (any Error).self) { try settings.endpoint() }
        }
    }
}
