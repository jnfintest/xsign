import XCTest
@testable import XSignCore

final class AppVersionTests: XCTestCase {
    func testParsing() {
        XCTAssertEqual(AppVersion("v1.2.3").components, [1, 2, 3])
        XCTAssertEqual(AppVersion("1.2.3-beta.2").prerelease, "beta.2")
        XCTAssertEqual(AppVersion("1.4 (42)").components, [1, 4])
        XCTAssertEqual(AppVersion("2.0.0+77").components, [2, 0, 0])
        XCTAssertFalse(AppVersion("nightly").isNumeric)
    }

    func testOrdering() {
        XCTAssertLessThan(AppVersion("1.2.9"), AppVersion("1.10.0"))
        XCTAssertLessThan(AppVersion("1.2"), AppVersion("1.2.1"))
        XCTAssertEqual(AppVersion("1.2"), AppVersion("1.2.0"))
        XCTAssertLessThan(AppVersion("1.3.0-beta.1"), AppVersion("1.3.0"))
        XCTAssertLessThan(AppVersion("1.3.0-beta.2"), AppVersion("1.3.0-beta.10"))
    }
}

final class ReleaseComparisonTests: XCTestCase {
    private func release(_ id: String, _ version: String, build: String? = nil) -> ReleaseInfo {
        ReleaseInfo(id: id, version: version, build: build,
                    asset: ReleaseAsset(name: "a.ipa", size: nil, downloadURL: URL(string: "https://x/a.ipa")!, isGitHubAPIAsset: false))
    }

    func testUpdateDetection() {
        let installed = InstalledRecord(releaseID: "v1.2.0", releaseVersion: "1.2.0", build: "10")
        XCTAssertTrue(release("v1.3.0", "1.3.0").isUpdate(over: installed))
        XCTAssertFalse(release("v1.2.0", "1.2.0").isUpdate(over: installed))
        XCTAssertFalse(release("v1.1.0", "1.1.0").isUpdate(over: installed))
        XCTAssertTrue(release("1.2.0+11", "1.2.0", build: "11").isUpdate(over: installed))
        XCTAssertTrue(release("v1.0.0", "1.0.0").isUpdate(over: nil))
    }
}

final class GlobTests: XCTestCase {
    func testGlob() {
        XCTAssertTrue(globMatch("*.ipa", "MyApp.ipa"))
        XCTAssertTrue(globMatch("MyApp-*.ipa", "myapp-1.2.0.IPA"))
        XCTAssertFalse(globMatch("*.ipa", "MyApp.zip"))
        XCTAssertTrue(globMatch("app-?.ipa", "app-1.ipa"))
        XCTAssertFalse(globMatch("app-?.ipa", "app-12.ipa"))
    }
}

final class ProvisioningProfileTests: XCTestCase {
    private func profileData(appID: String) -> Data {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Name</key><string>XSign Dev</string>
          <key>TeamName</key><string>Example Team</string>
          <key>TeamIdentifier</key><array><string>ABCDE12345</string></array>
          <key>ExpirationDate</key><date>2030-01-01T00:00:00Z</date>
          <key>ProvisionedDevices</key><array><string>0000</string><string>1111</string></array>
          <key>Entitlements</key><dict>
            <key>application-identifier</key><string>\(appID)</string>
            <key>get-task-allow</key><true/>
          </dict>
        </dict></plist>
        """
        // Surround with junk bytes to mimic the CMS envelope.
        return Data([0x30, 0x82, 0x01]) + Data(plist.utf8) + Data([0x00, 0xA0])
    }

    func testParseWildcard() throws {
        let profile = try ProvisioningProfile.parse(profileData(appID: "ABCDE12345.*"))
        XCTAssertEqual(profile.name, "XSign Dev")
        XCTAssertEqual(profile.teamIdentifier, "ABCDE12345")
        XCTAssertEqual(profile.deviceCount, 2)
        XCTAssertTrue(profile.isWildcard)
        XCTAssertTrue(profile.getTaskAllow)
        XCTAssertFalse(profile.isExpired(at: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(profile.signingBundleIdentifier(for: "com.me.myapp"), "com.me.myapp")
    }

    func testExplicitProfileDictatesBundleID() throws {
        let profile = try ProvisioningProfile.parse(profileData(appID: "ABCDE12345.com.me.myapp"))
        XCTAssertFalse(profile.isWildcard)
        XCTAssertEqual(profile.signingBundleIdentifier(for: "com.other.app"), "com.me.myapp")
        XCTAssertTrue(profile.allows(bundleIdentifier: "com.me.myapp"))
        XCTAssertFalse(profile.allows(bundleIdentifier: "com.other.app"))
    }

    func testWildcardPrefixAllows() throws {
        let profile = try ProvisioningProfile.parse(profileData(appID: "ABCDE12345.com.me.*"))
        XCTAssertTrue(profile.allows(bundleIdentifier: "com.me.myapp"))
        XCTAssertFalse(profile.allows(bundleIdentifier: "com.other.otherapp"))
        XCTAssertTrue(try ProvisioningProfile.parse(profileData(appID: "ABCDE12345.*")).allows(bundleIdentifier: "anything"))
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try ProvisioningProfile.parse(Data("hello".utf8)))
    }
}

final class SourceInputTests: XCTestCase {
    func testParsesGitHubForms() {
        let expected = SourceKind.github(GitHubSource(owner: "octocat", repo: "myapp"))
        XCTAssertEqual(SourceKind.parse("octocat/myapp"), expected)
        XCTAssertEqual(SourceKind.parse("https://github.com/octocat/myapp"), expected)
        XCTAssertEqual(SourceKind.parse("github.com/octocat/myapp/releases/tag/v1"), expected)
        XCTAssertEqual(SourceKind.parse(" https://github.com/octocat/myapp.git\n"), expected)
        XCTAssertNil(SourceKind.parse("https://github.com/octocat"))
        XCTAssertNil(SourceKind.parse(""))
    }

    func testParsesFeeds() {
        XCTAssertEqual(SourceKind.parse("https://example.com/apps.json"),
                       .feed(FeedSource(url: URL(string: "https://example.com/apps.json")!)))
        XCTAssertEqual(SourceKind.parse("nas.local/apps.json"),
                       .feed(FeedSource(url: URL(string: "https://nas.local/apps.json")!)))
        XCTAssertEqual(SourceKind.parse("https://raw.githubusercontent.com/o/r/main/source.json"),
                       .feed(FeedSource(url: URL(string: "https://raw.githubusercontent.com/o/r/main/source.json")!)))
    }
}

final class FeedTests: XCTestCase {
    func testXSignFeed() throws {
        let json = """
        {"name":"MyApp","bundleIdentifier":"com.me.myapp","releases":[
          {"version":"1.3.0","build":"30","url":"builds/myapp-1.3.0.ipa","sha256":"abc"},
          {"version":"1.5.0-beta","url":"builds/b.ipa","prerelease":true},
          {"version":"1.4.0","build":"42","date":"2026-11-19T10:00:00Z","notes":"Faster sync","url":"https://nas.local/f-1.4.0.ipa"}
        ]}
        """
        let catalog = try FeedClient.parse(Data(json.utf8), baseURL: URL(string: "https://nas.local/feeds/myapp.json"))
        XCTAssertEqual(catalog.apps.count, 1)
        let app = catalog.apps[0]
        XCTAssertEqual(app.id, "com.me.myapp")
        XCTAssertEqual(app.versions.map(\.version), ["1.5.0-beta", "1.4.0", "1.3.0"])
        XCTAssertEqual(app.latest(includeBetas: false)?.version, "1.4.0")
        XCTAssertEqual(app.latest(includeBetas: true)?.version, "1.5.0-beta")
        XCTAssertEqual(app.versions[1].id, "1.4.0+42")
        XCTAssertNotNil(app.versions[1].publishedAt)
        XCTAssertEqual(app.versions[2].asset.downloadURL.absoluteString, "https://nas.local/feeds/builds/myapp-1.3.0.ipa")
        XCTAssertEqual(app.versions[2].asset.sha256, "abc")
    }

    func testAltStoreSourceWithManyApps() throws {
        let json = """
        {"name":"Home Lab","iconURL":"icon.png","apps":[
          {"name":"Other","bundleIdentifier":"com.other","developerName":"Me","tintColor":"FF375F",
           "versions":[{"version":"9.0","downloadURL":"https://x/o.ipa"}]},
          {"name":"MyApp","bundleIdentifier":"com.me.myapp","beta":true,"versions":[
            {"version":"2.0","buildVersion":"5","date":"2026-11-01","downloadURL":"https://x/f2.ipa","size":10}
          ]},
          {"name":"Legacy","bundleIdentifier":"com.legacy","version":"1.0","downloadURL":"https://x/l.ipa"},
          {"name":"Empty","bundleIdentifier":"com.empty","versions":[]}
        ]}
        """
        let catalog = try FeedClient.parse(Data(json.utf8), baseURL: URL(string: "https://lab.example/source.json"))
        XCTAssertEqual(catalog.name, "Home Lab")
        XCTAssertEqual(catalog.iconURL?.absoluteString, "https://lab.example/icon.png")
        XCTAssertEqual(catalog.apps.map(\.name), ["Other", "MyApp", "Legacy"])
        XCTAssertEqual(catalog.apps[0].tintHex, "#FF375F")
        XCTAssertEqual(catalog.apps[1].versions[0].build, "5")
        XCTAssertTrue(catalog.apps[1].versions[0].isPrerelease)
        XCTAssertNil(catalog.apps[1].latest(includeBetas: false))
        XCTAssertEqual(catalog.apps[2].versions[0].version, "1.0")
    }

    func testInvalidFeed() {
        XCTAssertThrowsError(try FeedClient.parse(Data(#"{"foo":1}"#.utf8)))
        XCTAssertThrowsError(try FeedClient.parse(Data("[1,2]".utf8)))
    }

    func testBrokenEntriesAreSkippedNotFatal() throws {
        let json = """
        {"name":"Big","apps":[
          {"name":"Good","bundleIdentifier":"com.good","versions":[
            {"version":"1.0","buildVersion":7,"size":"2048","downloadURL":"https://x/g.ipa"},
            {"version":"0.9","downloadURL":42},
            {"version":"0.8"}
          ]},
          "not an app",
          {"name":["wrong"],"bundleIdentifier":"com.weird","beta":"true","versions":[{"version":"2.0","size":1.5e3,"downloadURL":"https://x/w.ipa"}]}
        ]}
        """
        let catalog = try FeedClient.parse(Data(json.utf8))
        XCTAssertEqual(catalog.apps.map(\.id), ["com.good", "com.weird"])
        XCTAssertEqual(catalog.apps[0].versions.count, 1)
        XCTAssertEqual(catalog.apps[0].versions[0].build, "7")
        XCTAssertEqual(catalog.apps[0].versions[0].asset.size, 2048)
        XCTAssertEqual(catalog.apps[1].name, "com.weird")
        XCTAssertTrue(catalog.apps[1].versions[0].isPrerelease)
        XCTAssertEqual(catalog.apps[1].versions[0].asset.size, 1500)
    }

    func testDuplicateBundleIDsGetUniqueIDs() throws {
        let json = """
        {"apps":[
          {"name":"A","bundleIdentifier":"com.dup","versions":[{"version":"1","downloadURL":"https://x/a.ipa"}]},
          {"name":"B","bundleIdentifier":"com.dup","versions":[{"version":"1","downloadURL":"https://x/b.ipa"}]},
          {"name":"C","bundleIdentifier":"com.dup","versions":[{"version":"1","downloadURL":"https://x/c.ipa"}]}
        ]}
        """
        let catalog = try FeedClient.parse(Data(json.utf8))
        XCTAssertEqual(catalog.apps.map(\.id), ["com.dup", "com.dup#2", "com.dup#3"])
        XCTAssertEqual(catalog.apps.map(\.bundleIdentifier), ["com.dup", "com.dup", "com.dup"])
    }

    func testKeepsOnlyNewestVersions() throws {
        let versions = (1...40).map { #"{"version":"1.\#($0)","downloadURL":"https://x/\#($0).ipa"}"# }
        let json = #"{"apps":[{"name":"Many","bundleIdentifier":"com.many","versions":[\#(versions.joined(separator: ","))]}]}"#
        let app = try FeedClient.parse(Data(json.utf8)).apps[0]
        XCTAssertEqual(app.versions.count, FeedClient.maxVersionsPerApp)
        XCTAssertEqual(app.versions.first?.version, "1.40")
    }

    func testDateFormats() {
        XCTAssertNotNil(FeedClient.parseDate("2026-11-19T10:00:00Z"))
        XCTAssertNotNil(FeedClient.parseDate("2026-11-19T10:00:00.123Z"))
        XCTAssertNotNil(FeedClient.parseDate("2026-11-19T10:00:00-05:00"))
        XCTAssertNotNil(FeedClient.parseDate("2026-11-19"))
        XCTAssertNil(FeedClient.parseDate("yesterday"))
    }
}

final class GitHubClientTests: XCTestCase {
    struct StubHTTP: HTTPClient {
        let routes: [String: (Int, String)]
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tkn")
            let path = request.url!.path
            let (status, body) = routes[path] ?? (404, #"{"message":"Not Found"}"#)
            let headers = ["X-RateLimit-Limit": "5000", "X-RateLimit-Remaining": "4990", "X-RateLimit-Reset": "1800000000"]
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            return (Data(body.utf8), response)
        }
    }

    static let repo = #"{"name":"myapp","description":"Money","owner":{"login":"o","avatar_url":"https://avatars.example/o.png"}}"#
    static let releases = """
    [
      {"tag_name":"v1.5.0","name":"Draft","body":"","draft":true,"prerelease":false,"published_at":null,"html_url":null,"assets":[]},
      {"tag_name":"v1.4.0-beta","name":"Beta","body":"","draft":false,"prerelease":true,"published_at":"2026-11-18T00:00:00Z","html_url":null,
       "assets":[{"id":3,"name":"MyApp.ipa","size":1,"url":"https://api.github.com/repos/o/r/releases/assets/3","browser_download_url":"https://github.com/x"}]},
      {"tag_name":"v1.3.0","name":"Stable","body":"Notes","draft":false,"prerelease":false,"published_at":"2026-11-10T00:00:00Z","html_url":"https://github.com/o/r/releases/tag/v1.3.0",
       "assets":[{"id":1,"name":"dSYMs.zip","size":1,"url":"https://api.github.com/repos/o/r/releases/assets/1","browser_download_url":null},
                 {"id":2,"name":"MyApp.ipa","size":2048,"url":"https://api.github.com/repos/o/r/releases/assets/2","browser_download_url":null,"digest":"sha256:abc123"}]},
      {"tag_name":"v1.2.0","name":"No IPA","body":"","draft":false,"prerelease":false,"published_at":null,"html_url":null,"assets":[]}
    ]
    """

    func testCatalogFromReleases() async throws {
        let http = StubHTTP(routes: ["/repos/o/r": (200, Self.repo), "/repos/o/r/releases": (200, Self.releases)])
        let client = GitHubReleaseClient(token: "tkn", http: http)
        let (catalog, rate) = try await client.catalog(for: GitHubSource(owner: "o", repo: "r"))

        XCTAssertEqual(catalog.name, "myapp")
        XCTAssertEqual(catalog.apps.count, 1)
        let app = catalog.apps[0]
        XCTAssertEqual(app.id, "github:o/r")
        XCTAssertEqual(app.developer, "o")
        XCTAssertEqual(app.summary, "Money")
        XCTAssertEqual(app.versions.map(\.id), ["v1.4.0-beta", "v1.3.0"])
        XCTAssertTrue(app.versions[0].isPrerelease)

        let stable = try XCTUnwrap(app.latest(includeBetas: false))
        XCTAssertEqual(stable.version, "1.3.0")
        XCTAssertEqual(stable.asset.name, "MyApp.ipa")
        XCTAssertEqual(stable.asset.size, 2048)
        XCTAssertEqual(stable.asset.sha256, "abc123")

        let request = client.downloadRequest(for: stable.asset)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/octet-stream")
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/o/r/releases/assets/2")

        XCTAssertEqual(rate?.limit, 5000)
        XCTAssertEqual(rate?.remaining, 4990)
        XCTAssertEqual(rate?.isAnonymous, false)
    }

    func testNotFoundMapsToHelpfulError() async {
        let client = GitHubReleaseClient(token: "tkn", http: StubHTTP(routes: [:]))
        do {
            _ = try await client.catalog(for: GitHubSource(owner: "o", repo: "r"))
            XCTFail("expected error")
        } catch let error as SourceError {
            XCTAssertEqual(error, .notFound("Repository o/r"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}

final class InstallManifestTests: XCTestCase {
    func testManifestAndURL() throws {
        let data = try InstallManifest.data(bundleIdentifier: "com.me.myapp", version: "1.4.0", title: "MyApp",
                                            packageURL: URL(string: "https://localhost.example:4443/t/app.ipa")!)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let item = (plist?["items"] as? [[String: Any]])?.first
        let metadata = item?["metadata"] as? [String: String]
        XCTAssertEqual(metadata?["bundle-identifier"], "com.me.myapp")
        XCTAssertEqual((item?["assets"] as? [[String: String]])?.first?["kind"], "software-package")

        let url = InstallManifest.installURL(manifestURL: URL(string: "https://localhost.example:4443/t/manifest.plist")!)
        XCTAssertTrue(url?.absoluteString.hasPrefix("itms-services://?action=download-manifest&url=https") ?? false)
    }
}

final class TrustProfileTests: XCTestCase {
    func testMobileconfigCarriesTheRootCertificate() throws {
        let der = Data([0x30, 0x82, 0x01, 0x0a])
        let data = try TrustProfile.mobileconfig(rootDER: der, name: "XSign Local Install AB12", identifier: "app.xsign.install")
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["PayloadType"] as? String, "Configuration")
        XCTAssertEqual(plist["PayloadIdentifier"] as? String, "app.xsign.install")
        let payload = try XCTUnwrap((plist["PayloadContent"] as? [[String: Any]])?.first)
        XCTAssertEqual(payload["PayloadType"] as? String, "com.apple.security.root")
        XCTAssertEqual(payload["PayloadContent"] as? Data, der)
        XCTAssertNotEqual(payload["PayloadUUID"] as? String, plist["PayloadUUID"] as? String)
    }

    func testDERCertificatesFromPEM() {
        let pem = """
        -----BEGIN CERTIFICATE-----
        AQID
        BA==
        -----END CERTIFICATE-----
        -----BEGIN PRIVATE KEY-----
        BQY=
        -----END PRIVATE KEY-----
        -----BEGIN CERTIFICATE-----
        CQk=
        -----END CERTIFICATE-----
        """
        XCTAssertEqual(TrustProfile.derCertificates(fromPEM: pem), [Data([1, 2, 3, 4]), Data([9, 9])])
        XCTAssertEqual(TrustProfile.derCertificates(fromPEM: "nothing"), [])
    }
}
